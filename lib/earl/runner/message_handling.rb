# frozen_string_literal: true

module Earl
  class Runner
    # Message routing: receives user messages, dispatches commands or enqueues for Claude.
    module MessageHandling
      private

      def setup_message_handler
        @services.mattermost.on_message do |sender_name:, thread_id:, text:, channel_id:, **_extra|
          if allowed_user?(sender_name)
            msg = UserMessage.new(thread_id: thread_id, text: text, channel_id: channel_id,
                                  sender_name: sender_name)
            handle_incoming_message(msg)
          end
        end
      end

      def handle_incoming_message(msg)
        if CommandParser.command?(msg.text)
          dispatch_command(msg)
        else
          enqueue_message(msg)
        end
      end

      def dispatch_command(msg)
        command = CommandParser.parse(msg.text)
        return unless command

        thread_id = msg.thread_id
        result = @services.command_executor.execute(command, thread_id: thread_id, channel_id: msg.channel_id)
        enqueue_passthrough(result, msg) if result&.dig(:passthrough)
        stop_active_response(thread_id) if %i[stop kill].include?(command.name)
      end

      def enqueue_passthrough(result, msg)
        msg_thread_id, _text, msg_channel_id, msg_sender = msg.deconstruct
        passthrough_msg = UserMessage.new(
          thread_id: msg_thread_id, text: result[:passthrough],
          channel_id: msg_channel_id, sender_name: msg_sender
        )
        enqueue_message(passthrough_msg)
      end

      def enqueue_message(msg)
        thread_id = msg.thread_id
        queue = @app_state.message_queue
        if queue.try_claim(thread_id)
          process_message(msg)
        else
          queue.enqueue(thread_id, msg.text)
        end
      end

      def process_message(msg)
        sent = false
        thread_id = msg.thread_id
        sent = process_message_send(msg, thread_id)
      rescue StandardError => error
        log_processing_error(thread_id, error)
      ensure
        cleanup_failed_send(thread_id) unless sent
      end

      def process_message_send(msg, thread_id)
        text = msg.text
        effective_channel = msg.channel_id || @services.config.channel_id
        existing_session, session = prepare_session(thread_id, effective_channel, msg.sender_name)
        prepare_response(session, thread_id, effective_channel)
        message = existing_session ? text : build_contextual_message(thread_id, text)
        send_and_touch(session, thread_id, message)
      end

      def send_and_touch(session, thread_id, message)
        sent = session.send_message(message)
        @services.session_manager.touch(thread_id) if sent
        sent
      end

      def prepare_session(thread_id, channel_id, sender_name)
        working_dir = resolve_working_dir(thread_id, channel_id)
        manager = @services.session_manager
        existing = manager.get(thread_id)
        session_config = SessionManager::SessionConfig.new(
          channel_id: channel_id, working_dir: working_dir, username: sender_name
        )
        session = manager.get_or_create(thread_id, session_config)
        [existing, session]
      end

      def resolve_working_dir(thread_id, channel_id)
        @services.command_executor.working_dir_for(thread_id) || @services.config.channels[channel_id] || Dir.pwd
      end

      def build_contextual_message(thread_id, text)
        ThreadContextBuilder.new(mattermost: @services.mattermost).build(thread_id, text)
      end

      def process_next_queued(thread_id)
        next_text = @app_state.message_queue.dequeue(thread_id)
        return unless next_text

        msg = UserMessage.new(thread_id: thread_id, text: next_text, channel_id: nil, sender_name: nil)
        process_message(msg)
      end

      def allowed_user?(username)
        allowed = @services.config.allowed_users
        return true if allowed.empty?

        unless allowed.include?(username)
          log(:debug, "Ignoring message from non-allowed user: #{username}")
          return false
        end

        true
      end
    end
  end
end
