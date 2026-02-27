# frozen_string_literal: true

module Earl
  class Runner
    # Message routing: receives user messages, dispatches commands or enqueues for Claude.
    module MessageHandling
      private

      def setup_message_handler
        @services.mattermost.on_message do |**params|
          receive_message(params) if allowed_user?(params[:sender_name])
        end
      end

      def receive_message(params)
        handle_incoming_message(build_user_message(params))
      end

      def build_user_message(params)
        UserMessage.new(**params.slice(:thread_id, :text, :channel_id, :sender_name),
                        file_ids: params.fetch(:file_ids, []))
      end

      def handle_incoming_message(msg)
        CommandParser.command?(msg.text) ? dispatch_command(msg) : enqueue_message(msg)
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
          queue.enqueue(thread_id, msg)
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
        effective_channel = msg.channel_id || @services.config.channel_id
        existing_session, session = prepare_session(thread_id, effective_channel, msg.sender_name)
        prepare_response(session, thread_id, effective_channel)
        raw_text = msg.text
        text = existing_session ? raw_text : build_contextual_text(thread_id, raw_text)
        content = attach_images(text, msg.file_ids)
        send_and_touch(session, thread_id, content)
      end

      def build_contextual_text(thread_id, text)
        ThreadContextBuilder.new(mattermost: @services.mattermost).build(thread_id, text)
      end

      def attach_images(text, file_ids)
        return text if file_ids.empty?

        content_builder.build(text, file_ids)
      end

      def content_builder
        @content_builder ||= ImageSupport::ContentBuilder.new(mattermost: @services.mattermost)
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

      def process_next_queued(thread_id)
        queued = @app_state.message_queue.dequeue(thread_id)
        return unless queued

        msg = queued.is_a?(UserMessage) ? queued : UserMessage.new(thread_id: thread_id, text: queued)
        process_message(msg)
      end

      def allowed_user?(username)
        allowed = @services.config.allowed_users
        return true if allowed.empty? || allowed.include?(username)

        log(:debug, "Ignoring message from non-allowed user: #{username}")
        false
      end
    end
  end
end
