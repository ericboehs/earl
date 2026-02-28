# frozen_string_literal: true

require_relative "callback_wiring"

module Earl
  class Runner
    # Streaming response lifecycle: creates responses, wires callbacks, handles completion.
    module ResponseLifecycle
      include CallbackWiring

      # Bundles response context that travels together through the lifecycle.
      ResponseBundle = Struct.new(:session, :response, :thread_id, keyword_init: true)

      private

      def prepare_response(session, thread_id, channel_id)
        response = StreamingResponse.new(thread_id: thread_id, mattermost: @services.mattermost, channel_id: channel_id)
        @responses.active_responses[thread_id] = response
        response.start_typing
        bundle = ResponseBundle.new(session: session, response: response, thread_id: thread_id)
        wire_all_callbacks(bundle)
        response
      end

      def handle_tool_use(thread_id:, tool_use:, channel_id:)
        result = @services.question_handler.handle_tool_use(thread_id: thread_id, tool_use: tool_use,
                                                            channel_id: channel_id)
        return unless result.is_a?(Hash)

        tool_use_id = result[:tool_use_id]
        @responses.question_threads[tool_use_id] = thread_id if tool_use_id
      end

      def handle_response_complete(thread_id)
        response = @responses.active_responses.delete(thread_id)
        session = @services.session_manager.get(thread_id)
        followup_sent = complete_response(thread_id, session, response)

        # Skip queue release when a follow-up is streaming — its own
        # on_complete callback will call handle_response_complete again.
        process_next_queued(thread_id) unless followup_sent
      end

      def complete_response(thread_id, session, response)
        unless session && response
          log_missing_completion(thread_id, response)
          return false
        end

        bundle = ResponseBundle.new(session: session, response: response, thread_id: thread_id)
        finalize_response(bundle)
        send_analysis_followup_if_needed(bundle)
      end

      def finalize_response(bundle)
        session, response, thread_id = bundle.deconstruct
        stats = session.stats
        response.on_complete
        log_session_stats(stats, thread_id)
        @services.session_manager.save_stats(thread_id)
      end

      def log_missing_completion(thread_id, response)
        log(:warn, "Completion for thread #{thread_id[0..7]} with missing session or response (likely killed)")
        response&.stop_typing
      end

      def log_session_stats(stats, thread_id)
        summary = stats.format_summary("Thread #{thread_id[0..7]} complete")
        log(:info, summary)
      end

      def log_processing_error(thread_id, error)
        log(:error, "Error processing message for thread #{thread_id[0..7]}: #{error.message}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
      end

      def stop_active_response(thread_id)
        response = @responses.active_responses.delete(thread_id)
        response&.stop_typing
        @app_state.message_queue.dequeue(thread_id)
      end

      def cleanup_failed_send(thread_id)
        response = @responses.active_responses.delete(thread_id)
        response&.stop_typing
        @app_state.message_queue.release(thread_id)
      end

      # Detects analysis responses missing a "## Suggested Fixes" section and
      # automatically sends a follow-up prompt to the same Claude session.
      # Requires a markdown heading (## Root Cause, ## What Happened, etc.) plus
      # analysis keywords to avoid false positives on normal conversation.
      module AnalysisFollowup
        ANALYSIS_HEADINGS = /^##\s+(?:Root Cause|What (?:Went Wrong|Happened)|Analysis|Investigation)/im
        ANALYSIS_KEYWORDS = /went wrong|root cause|should have|the problem|misunderstood|misinterpreted|what happened/i
        SUGGESTED_FIXES_HEADING = /^##\s+(?:Suggested|Recommended)\s+Fix(?:es)?/im
        MIN_ANALYSIS_LENGTH = 300

        private

        def send_analysis_followup_if_needed(bundle)
          session, response, thread_id = bundle.deconstruct
          return false if @followup_sent&.include?(thread_id)
          return false unless needs_fixes_followup?(response.full_text)

          dispatch_followup(session, response, thread_id)
          true
        rescue StandardError => error
          short_id = thread_id[0..7]
          log(:error, "Analysis follow-up failed for thread #{short_id}: #{error.message}")
          log(:error, error.backtrace&.first(5)&.join("\n"))
          false
        end

        def dispatch_followup(session, response, thread_id)
          short_id = thread_id[0..7]
          log(:info, "Analysis response in thread #{short_id} missing ## Suggested Fixes — sending follow-up")
          (@followup_sent ||= Set.new) << thread_id
          prepare_response(session, thread_id, response.channel_id)
          sent = session.send_message(followup_prompt)
          log(:warn, "Follow-up send failed for thread #{short_id} (session dead)") unless sent
        end

        def needs_fixes_followup?(text)
          return false if text.to_s.length < MIN_ANALYSIS_LENGTH
          return false unless ANALYSIS_HEADINGS.match?(text)
          return false unless ANALYSIS_KEYWORDS.match?(text)

          !SUGGESTED_FIXES_HEADING.match?(text)
        end

        def followup_prompt
          "Now add a `## Suggested Fixes` section with numbered fixes. " \
            "Each fix must name a specific file path and include a fenced code block with the exact change."
        end
      end

      include AnalysisFollowup
    end
  end
end
