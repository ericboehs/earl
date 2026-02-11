# frozen_string_literal: true

module Earl
  # Main event loop that connects Mattermost messages to Claude sessions,
  # managing per-thread message queuing and streaming response delivery.
  class Runner
    include Logging

    def initialize
      @config = Config.new
      @session_manager = SessionManager.new
      @mattermost = Mattermost.new(@config)
      @shutting_down = false
      @message_queue = MessageQueue.new
    end

    def start
      setup_signal_handlers
      setup_message_handler
      @mattermost.connect
      log_startup
      sleep 0.5 until @shutting_down
    end

    private

    def log_startup
      log(:info, "EARL is running. Listening for messages in channel #{@config.channel_id[0..7]}...")
      log(:info, "Allowed users: #{@config.allowed_users.join(', ')}")
    end

    def setup_signal_handlers
      %w[INT TERM].each { |signal| trap(signal) { handle_shutdown_signal } }
    end

    def handle_shutdown_signal
      return if @shutting_down

      @shutting_down = true
      Thread.new { shutdown }
    end

    def shutdown
      log(:info, "Shutting down...")
      @session_manager.stop_all
      log(:info, "Goodbye!")
      exit 0
    end

    def setup_message_handler
      @mattermost.on_message do |sender_name:, thread_id:, text:, post_id:|
        enqueue_message(thread_id: thread_id, text: text) if allowed_user?(sender_name)
      end
    end

    def allowed_user?(username)
      allowed = @config.allowed_users
      return true if allowed.empty?

      unless allowed.include?(username)
        log(:debug, "Ignoring message from non-allowed user: #{username}")
        return false
      end

      true
    end

    def enqueue_message(thread_id:, text:)
      if @message_queue.try_claim(thread_id)
        process_message(thread_id: thread_id, text: text)
      else
        @message_queue.enqueue(thread_id, text)
      end
    end

    def process_message(thread_id:, text:)
      session = @session_manager.get_or_create(thread_id)
      response = StreamingResponse.new(
        thread_id: thread_id, mattermost: @mattermost, channel_id: @config.channel_id
      )
      response.start_typing

      setup_callbacks(session, response, thread_id)
      session.send_message(text)
    end

    def setup_callbacks(session, response, thread_id)
      session.on_text { |accumulated_text| response.on_text(accumulated_text) }
      session.on_complete { |_| handle_response_complete(session, response, thread_id) }
    end

    def handle_response_complete(session, response, thread_id)
      response.on_complete
      log(:info, "Response complete for thread #{thread_id[0..7]} (cost=$#{session.total_cost})")
      process_next_queued(thread_id)
    end

    def process_next_queued(thread_id)
      next_text = @message_queue.dequeue(thread_id)
      process_message(thread_id: thread_id, text: next_text) if next_text
    end
  end
end
