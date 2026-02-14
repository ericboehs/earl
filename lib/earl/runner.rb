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
      @heartbeat_scheduler = HeartbeatScheduler.new(
        config: @config, session_manager: @session_manager, mattermost: @mattermost
      )
      @command_executor = CommandExecutor.new(
        session_manager: @session_manager, mattermost: @mattermost, config: @config,
        heartbeat_scheduler: @heartbeat_scheduler
      )
      @question_handler = QuestionHandler.new(mattermost: @mattermost)
      @app_state = AppState.new(shutting_down: false, message_queue: MessageQueue.new)
      @question_threads = {} # tool_use_id -> thread_id
      @active_responses = {} # thread_id -> StreamingResponse
      @idle_checker_thread = nil

      configure_channels
    end

    # :reek:TooManyStatements
    def start
      setup_signal_handlers
      setup_message_handler
      setup_reaction_handler
      @session_manager.resume_all
      start_idle_checker
      @heartbeat_scheduler.start
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
      @heartbeat_scheduler.stop
      @session_manager.pause_all
      log(:info, "Goodbye!")
      exit 0
    end

    def setup_message_handler
      @mattermost.on_message do |sender_name:, thread_id:, text:, post_id:, channel_id:|
        if allowed_user?(sender_name)
          handle_incoming_message(thread_id: thread_id, text: text, channel_id: channel_id,
                                 sender_name: sender_name)
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

    def handle_incoming_message(thread_id:, text:, channel_id:, sender_name: nil)
      if CommandParser.command?(text)
        command = CommandParser.parse(text)
        if command
          @command_executor.execute(command, thread_id: thread_id, channel_id: channel_id)
          stop_active_response(thread_id) if %i[stop kill].include?(command.name)
        end
      else
        enqueue_message(thread_id: thread_id, text: text, channel_id: channel_id, sender_name: sender_name)
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

    def enqueue_message(thread_id:, text:, channel_id: nil, sender_name: nil)
      queue = @app_state.message_queue
      if queue.try_claim(thread_id)
        process_message(thread_id: thread_id, text: text, channel_id: channel_id, sender_name: sender_name)
      else
        queue.enqueue(thread_id, text)
      end
    end

    # :reek:TooManyStatements
    def process_message(thread_id:, text:, channel_id: nil, sender_name: nil)
      effective_channel = channel_id || @config.channel_id
      working_dir = resolve_working_dir(thread_id, effective_channel)

      session = @session_manager.get_or_create(
        thread_id, channel_id: effective_channel, working_dir: working_dir, username: sender_name
      )
      response = StreamingResponse.new(
        thread_id: thread_id, mattermost: @mattermost, channel_id: effective_channel
      )
      @active_responses[thread_id] = response
      response.start_typing

      setup_callbacks(session, response, thread_id)
      session.send_message(text)
      @session_manager.touch(thread_id)
    rescue StandardError => error
      log(:error, "Error processing message for thread #{thread_id[0..7]}: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
      # Release the queue claim so future messages aren't permanently stuck
      @app_state.message_queue.dequeue(thread_id)
    end

    def resolve_working_dir(thread_id, channel_id)
      @command_executor.working_dir_for(thread_id) || @config.channels[channel_id] || Dir.pwd
    end

    # :reek:FeatureEnvy
    def setup_callbacks(session, response, thread_id)
      session.on_text { |text| response.on_text(text) }
      session.on_complete { |_| handle_response_complete(session, response, thread_id) }
      session.on_tool_use do |tool_use|
        response.on_tool_use(tool_use)
        handle_tool_use(thread_id, tool_use, response.channel_id)
      end
    end

    # :reek:FeatureEnvy
    def handle_tool_use(thread_id, tool_use, channel_id)
      result = @question_handler.handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: channel_id)
      tool_use_id = result[:tool_use_id] if result.is_a?(Hash)
      @question_threads[tool_use_id] = thread_id if tool_use_id
    end

    def handle_response_complete(session, response, thread_id)
      stats_line = build_stats_line(session)
      response.on_complete(stats_line: stats_line)
      @active_responses.delete(thread_id)
      log_session_stats(session, thread_id)
      @session_manager.save_stats(thread_id)
      process_next_queued(thread_id)
    end

    # :reek:FeatureEnvy
    def build_stats_line(session)
      stats = session.stats
      total = stats.total_input_tokens + stats.total_output_tokens
      return nil unless total.positive?

      line = "#{format_number(total)} tokens"
      pct = stats.context_percent
      line += format(" · %.0f%% context", pct) if pct
      line
    end

    # :reek:FeatureEnvy
    def log_session_stats(session, thread_id)
      log(:info, session.stats.format_summary("Thread #{thread_id[0..7]} complete"))
    end

    def process_next_queued(thread_id)
      next_text = @app_state.message_queue.dequeue(thread_id)
      process_message(thread_id: thread_id, text: next_text) if next_text
    end

    def find_thread_for_question(tool_use_id)
      @question_threads[tool_use_id]
    end

    def stop_active_response(thread_id)
      response = @active_responses.delete(thread_id)
      response&.stop_typing
      @app_state.message_queue.dequeue(thread_id)
    end

    def format_number(num)
      return "0" unless num

      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end

    # Idle session management extracted to reduce class method count.
    module IdleManagement
      private

      def start_idle_checker
        @idle_checker_thread = Thread.new do
          loop do
            sleep IDLE_CHECK_INTERVAL
            check_idle_sessions
          rescue StandardError => error
            log(:error, "Idle checker error: #{error.message}")
          end
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
