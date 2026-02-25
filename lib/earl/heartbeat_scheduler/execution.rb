# frozen_string_literal: true

module Earl
  class HeartbeatScheduler
    # Heartbeat execution: creates sessions, streams responses, handles completion.
    module Execution
      private

      def execute_heartbeat(state)
        definition = state.definition
        def_name = definition.name
        log(:info, "Heartbeat '#{def_name}' starting")
        thread_id = post_heartbeat_header(definition.channel_id, definition.description)
        return unless thread_id

        run_heartbeat_session(definition, state, thread_id)
      rescue StandardError => error
        handle_heartbeat_error(state, def_name, error)
      ensure
        finalize_heartbeat(state)
      end

      def handle_heartbeat_error(state, name, error)
        error_msg = error.message
        log(:error, "Heartbeat '#{name}' error: #{error_msg}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
        @mutex.synchronize { state.last_error = error_msg }
      end

      def post_heartbeat_header(channel_id, description)
        post = @deps.mattermost.create_post(channel_id: channel_id, message: "\u{1FAC0} **#{description}**")
        post&.dig("id")
      end

      def run_heartbeat_session(definition, state, thread_id)
        session = build_heartbeat_session(definition, state)
        completed = false
        response = build_heartbeat_response(thread_id, definition.channel_id)
        setup_heartbeat_callbacks(session, response) { completed = true }
        session.start
        session.send_message(definition.prompt)
        await_heartbeat_completion(session, definition.timeout) { completed }
        log(:info, "Heartbeat '#{definition.name}' completed (run ##{state.run_count + 1})")
      end

      def build_heartbeat_response(thread_id, channel_id)
        response = StreamingResponse.new(thread_id: thread_id, mattermost: @deps.mattermost, channel_id: channel_id)
        response.start_typing
        response
      end

      def build_heartbeat_session(definition, state)
        session_opts = heartbeat_session_opts(definition)
        persistent = definition.persistent
        apply_resume_opts(session_opts, state) if persistent
        session = ClaudeSession.new(**session_opts)
        @mutex.synchronize { state.session_id = session.session_id } if persistent
        session
      end

      def heartbeat_session_opts(definition)
        auto, channel_id, working_dir = definition.base_session_opts.values_at(:auto_permission, :channel_id,
                                                                               :working_dir)
        { working_dir: working_dir, permission_config: auto ? nil : heartbeat_permission_env(channel_id) }
      end

      def apply_resume_opts(opts, state)
        saved_session_id = state.session_id
        return unless saved_session_id

        opts[:session_id] = saved_session_id
        opts[:mode] = :resume
      end

      def heartbeat_permission_env(channel_id)
        @deps.config.permission_env(channel_id: channel_id)
      end

      def setup_heartbeat_callbacks(session, response)
        session.on_text { |text| response.on_text(text) }
        session.on_complete do |_|
          response.on_complete
          yield
        end
        session.on_tool_use { |tool_use| response.on_tool_use(tool_use) }
      end

      def await_heartbeat_completion(session, timeout)
        start_time = monotonic_now
        until yield
          if monotonic_now - start_time >= timeout
            log(:warn, "Heartbeat timed out after #{timeout}s")
            session.kill
            return
          end
          sleep 1
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
