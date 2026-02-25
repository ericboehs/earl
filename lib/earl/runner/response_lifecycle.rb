# frozen_string_literal: true

module Earl
  class Runner
    # Streaming response lifecycle: creates responses, wires callbacks, handles completion.
    module ResponseLifecycle
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

      def wire_all_callbacks(bundle)
        session, response, thread_id = bundle.deconstruct
        resp_channel_id = response.channel_id
        wire_text_callbacks(session, response)
        session.on_complete { |_| handle_response_complete(thread_id) }
        session.on_tool_use do |tool_use|
          response.on_tool_use(tool_use)
          handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: resp_channel_id)
        end
      end

      def wire_text_callbacks(session, response)
        session.on_text { |text| response.on_text(text) }
        session.on_system { |event| response.on_text(event[:message]) }
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

        if session && response
          bundle = ResponseBundle.new(session: session, response: response, thread_id: thread_id)
          finalize_response(bundle)
        else
          log_missing_completion(thread_id, response)
        end

        process_next_queued(thread_id)
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
    end
  end
end
