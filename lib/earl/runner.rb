# frozen_string_literal: true

module Earl
  # Main event loop that connects Mattermost messages to Claude sessions,
  # managing per-thread message queuing, command parsing, question handling,
  # and streaming response delivery.
  class Runner
    include Logging

    # Tracks runtime state: shutdown flag and per-thread message queue.
    AppState = Struct.new(:shutting_down, :message_queue, keyword_init: true)

    IDLE_CHECK_INTERVAL = 300 # 5 minutes
    IDLE_TIMEOUT = 1800 # 30 minutes

    def initialize
      @config = Config.new
      @session_store = SessionStore.new
      @session_manager = SessionManager.new(config: @config, session_store: @session_store)
      @mattermost = Mattermost.new(@config)
      @command_executor = CommandExecutor.new(
        session_manager: @session_manager, mattermost: @mattermost, config: @config
      )
      @question_handler = QuestionHandler.new(mattermost: @mattermost)
      @app_state = AppState.new(shutting_down: false, message_queue: MessageQueue.new)
      @idle_checker_thread = nil

      configure_channels
    end

    def start
      setup_signal_handlers
      setup_message_handler
      setup_reaction_handler
      @session_manager.resume_all
      start_idle_checker
      @mattermost.connect
      log_startup
      sleep 0.5 until @app_state.shutting_down
    end

    private

    def configure_channels
      channels = @config.channels
      @mattermost.configure_channels(Set.new(channels.keys)) if channels.size > 1
    end

    def log_startup
      log(:info, "EARL is running. Listening for messages in channel #{@config.channel_id[0..7]}...")
      log(:info, "Allowed users: #{@config.allowed_users.join(', ')}")
    end

    def setup_signal_handlers
      %w[INT TERM].each { |signal| trap(signal) { handle_shutdown_signal } }
    end

    def handle_shutdown_signal
      return if @app_state.shutting_down

      @app_state.shutting_down = true
      Thread.new { shutdown }
    end

    def shutdown
      log(:info, "Shutting down...")
      @idle_checker_thread&.kill
      @session_manager.pause_all
      log(:info, "Goodbye!")
      exit 0
    end

    def setup_message_handler
      @mattermost.on_message do |sender_name:, thread_id:, text:, post_id:, channel_id:|
        if allowed_user?(sender_name)
          handle_incoming_message(thread_id: thread_id, text: text, channel_id: channel_id)
        end
      end
    end

    def setup_reaction_handler
      @mattermost.on_reaction do |user_id:, post_id:, emoji_name:|
        handle_reaction(post_id: post_id, emoji_name: emoji_name)
      end
    end

    def handle_reaction(post_id:, emoji_name:)
      result = @question_handler.handle_reaction(post_id: post_id, emoji_name: emoji_name)
      return unless result

      thread_id = find_thread_for_question(result[:tool_use_id])
      return unless thread_id

      session = @session_manager.get(thread_id)
      session&.send_message(result[:answer_text])
    end

    def handle_incoming_message(thread_id:, text:, channel_id:)
      if CommandParser.command?(text)
        command = CommandParser.parse(text)
        @command_executor.execute(command, thread_id: thread_id, channel_id: channel_id) if command
      else
        enqueue_message(thread_id: thread_id, text: text, channel_id: channel_id)
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

    def enqueue_message(thread_id:, text:, channel_id: nil)
      queue = @app_state.message_queue
      if queue.try_claim(thread_id)
        process_message(thread_id: thread_id, text: text, channel_id: channel_id)
      else
        queue.enqueue(thread_id, text)
      end
    end

    def process_message(thread_id:, text:, channel_id: nil)
      effective_channel = channel_id || @config.channel_id
      working_dir = resolve_working_dir(thread_id, effective_channel)

      session = @session_manager.get_or_create(thread_id, channel_id: effective_channel, working_dir: working_dir)
      response = StreamingResponse.new(
        thread_id: thread_id, mattermost: @mattermost, channel_id: effective_channel
      )
      response.start_typing

      setup_callbacks(session, response, thread_id)
      session.send_message(text)
      @session_manager.touch(thread_id)
    end

    def resolve_working_dir(thread_id, channel_id)
      @command_executor.working_dir_for(thread_id) || @config.channels[channel_id] || Dir.pwd
    end

    # :reek:FeatureEnvy
    def setup_callbacks(session, response, thread_id)
      session.on_text { |accumulated_text| response.on_text(accumulated_text) }
      session.on_complete { |_| handle_response_complete(session, response, thread_id) }
      session.on_tool_use { |tool_use| handle_tool_use(thread_id, tool_use) }
    end

    def handle_tool_use(thread_id, tool_use)
      @question_handler.handle_tool_use(thread_id: thread_id, tool_use: tool_use)
    end

    def handle_response_complete(session, response, thread_id)
      response.on_complete
      log_session_stats(session, thread_id)
      process_next_queued(thread_id)
    end

    # :reek:FeatureEnvy
    def log_session_stats(session, thread_id)
      log(:info, session.stats.format_summary("Thread #{thread_id[0..7]} complete"))
    end

    def process_next_queued(thread_id)
      next_text = @app_state.message_queue.dequeue(thread_id)
      process_message(thread_id: thread_id, text: next_text) if next_text
    end

    def find_thread_for_question(_tool_use_id)
      nil
    end

    # Idle session management extracted to reduce class method count.
    module IdleManagement
      private

      def start_idle_checker
        @idle_checker_thread = Thread.new do
          loop do
            sleep IDLE_CHECK_INTERVAL
            check_idle_sessions
          end
        rescue StandardError => error
          log(:error, "Idle checker error: #{error.message}")
        end
      end

      def check_idle_sessions
        @session_store.load.each do |thread_id, persisted|
          pause_if_idle(thread_id, persisted)
        end
      end

      def pause_if_idle(thread_id, persisted)
        return if persisted.is_paused

        idle_seconds = Time.now - Time.parse(persisted.last_activity_at)
        return unless idle_seconds > IDLE_TIMEOUT

        log(:info, "Pausing idle session for thread #{thread_id[0..7]}")
        @session_manager.stop_session(thread_id)
      end
    end

    include IdleManagement
  end
end
