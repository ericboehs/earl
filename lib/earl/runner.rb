# frozen_string_literal: true

module Earl
  # Main event loop that connects Mattermost messages to Claude sessions,
  # managing per-thread message queuing, command parsing, question handling,
  # and streaming response delivery.
  class Runner
    include Logging
    include Formatting

    # Tracks runtime state: shutdown flag and per-thread message queue.
    AppState = Struct.new(:shutting_down, :message_queue, keyword_init: true)

    # Bundles user message parameters that travel together through message routing.
    UserMessage = Data.define(:thread_id, :text, :channel_id, :sender_name)

    IDLE_CHECK_INTERVAL = 300 # 5 minutes
    IDLE_TIMEOUT = 1800 # 30 minutes

    def initialize
      @config = Config.new
      @session_store = SessionStore.new
      @session_manager = SessionManager.new(config: @config, session_store: @session_store)
      @mattermost = Mattermost.new(@config)
      @tmux_store = TmuxSessionStore.new
      @heartbeat_scheduler = HeartbeatScheduler.new(
        config: @config, session_manager: @session_manager, mattermost: @mattermost
      )
      @command_executor = CommandExecutor.new(
        session_manager: @session_manager, mattermost: @mattermost, config: @config,
        heartbeat_scheduler: @heartbeat_scheduler, tmux_store: @tmux_store
      )
      @question_handler = QuestionHandler.new(mattermost: @mattermost)
      @tmux_monitor = TmuxMonitor.new(mattermost: @mattermost, tmux_store: @tmux_store)
      @app_state = AppState.new(shutting_down: false, message_queue: MessageQueue.new)
      @question_threads = {} # tool_use_id -> thread_id
      @active_responses = {} # thread_id -> StreamingResponse
      @idle_checker_thread = nil

      configure_channels
    end

    def start
      setup_handlers
      @session_manager.resume_all
      @tmux_store.cleanup!
      start_background_services
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

    def start_background_services
      start_idle_checker
      @heartbeat_scheduler.start
      @tmux_monitor.start
    end

    def setup_handlers
      setup_signal_handlers
      setup_message_handler
      setup_reaction_handler
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
      @tmux_monitor.stop
      @session_manager.pause_all
      log(:info, "Goodbye!")
      # No exit here — let the start method's sleep loop exit via shutting_down flag
    end

    def setup_message_handler
      @mattermost.on_message do |sender_name:, thread_id:, text:, post_id:, channel_id:|
        if allowed_user?(sender_name)
          msg = UserMessage.new(thread_id: thread_id, text: text, channel_id: channel_id,
                                sender_name: sender_name)
          handle_incoming_message(msg)
        end
      end
    end

    def setup_reaction_handler
      @mattermost.on_reaction do |user_id:, post_id:, emoji_name:|
        handle_reaction(user_id: user_id, post_id: post_id, emoji_name: emoji_name)
      end
    end

    def handle_reaction(user_id:, post_id:, emoji_name:)
      return unless allowed_reactor?(user_id)

      # Try EARL's own question handler first
      result = @question_handler.handle_reaction(post_id: post_id, emoji_name: emoji_name)
      if result
        thread_id = find_thread_for_question(result[:tool_use_id])
        return unless thread_id

        session = @session_manager.get(thread_id)
        session&.send_message(result[:answer_text])
        return
      end

      # Then try tmux monitor (forwarded questions/permissions)
      @tmux_monitor.handle_reaction(post_id: post_id, emoji_name: emoji_name)
    end

    def handle_incoming_message(msg)
      if CommandParser.command?(msg.text)
        command = CommandParser.parse(msg.text)
        if command
          result = @command_executor.execute(command, thread_id: msg.thread_id, channel_id: msg.channel_id)
          if result&.dig(:passthrough)
            passthrough_msg = UserMessage.new(
              thread_id: msg.thread_id, text: result[:passthrough],
              channel_id: msg.channel_id, sender_name: msg.sender_name
            )
            enqueue_message(passthrough_msg)
          end
          stop_active_response(msg.thread_id) if %i[stop kill].include?(command.name)
        end
      else
        enqueue_message(msg)
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

    def allowed_reactor?(user_id)
      allowed = @config.allowed_users
      return true if allowed.empty?

      username = lookup_username(user_id)
      return false unless username

      allowed.include?(username)
    end

    def lookup_username(user_id)
      @mattermost.get_user(user_id: user_id)["username"]
    end

    def enqueue_message(msg)
      queue = @app_state.message_queue
      if queue.try_claim(msg.thread_id)
        process_message(msg)
      else
        queue.enqueue(msg.thread_id, msg.text)
      end
    end

    def process_message(msg)
      effective_channel = msg.channel_id || @config.channel_id
      existing_session, session = prepare_session(msg.thread_id, effective_channel, msg.sender_name)
      response = prepare_response(session, msg.thread_id, effective_channel)
      sent = session.send_message(existing_session ? msg.text : build_contextual_message(msg.thread_id, msg.text))
      @session_manager.touch(msg.thread_id) if sent
    rescue StandardError => error
      log_processing_error(msg.thread_id, error)
    ensure
      cleanup_failed_send(response, msg.thread_id) unless sent
    end

    def prepare_session(thread_id, channel_id, sender_name)
      working_dir = resolve_working_dir(thread_id, channel_id)
      existing = @session_manager.get(thread_id)
      session_config = SessionManager::SessionConfig.new(
        channel_id: channel_id, working_dir: working_dir, username: sender_name
      )
      session = @session_manager.get_or_create(thread_id, session_config)
      [ existing, session ]
    end

    def log_processing_error(thread_id, error)
      log(:error, "Error processing message for thread #{thread_id[0..7]}: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
    end

    def resolve_working_dir(thread_id, channel_id)
      @command_executor.working_dir_for(thread_id) || @config.channels[channel_id] || Dir.pwd
    end

    def create_streaming_response(thread_id, channel_id)
      response = StreamingResponse.new(thread_id: thread_id, mattermost: @mattermost, channel_id: channel_id)
      @active_responses[thread_id] = response
      response.start_typing
      response
    end

    def prepare_response(session, thread_id, channel_id)
      response = create_streaming_response(thread_id, channel_id)
      setup_callbacks(session, response, thread_id)
      response
    end

    def build_contextual_message(thread_id, text)
      ThreadContextBuilder.new(mattermost: @mattermost).build(thread_id, text)
    end

    def setup_callbacks(session, response, thread_id)
      wire_stream_callbacks(session, response)
      wire_completion_callback(session, response, thread_id)
      channel_id = response.channel_id
      session.on_tool_use do |tool_use|
        response.on_tool_use(tool_use)
        handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: channel_id)
      end
    end

    def wire_stream_callbacks(session, response)
      session.on_text { |text| response.on_text(text) }
      session.on_system { |event| response.on_text(event[:message]) }
    end

    def wire_completion_callback(session, response, thread_id)
      session.on_complete { |_| handle_response_complete(session, response, thread_id) }
    end

    def handle_tool_use(thread_id:, tool_use:, channel_id:)
      result = @question_handler.handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: channel_id)
      return unless result.is_a?(Hash)

      tool_use_id = result[:tool_use_id]
      @question_threads[tool_use_id] = thread_id if tool_use_id
    end

    def handle_response_complete(session, response, thread_id)
      stats = session.stats
      response.on_complete(stats_line: build_stats_line(stats.total_input_tokens, stats.total_output_tokens,
                                                        stats.context_percent))
      @active_responses.delete(thread_id)
      log_session_stats(stats, thread_id)
      @session_manager.save_stats(thread_id)
      process_next_queued(thread_id)
    end

    def build_stats_line(input_tokens, output_tokens, context_pct)
      total_tokens = input_tokens + output_tokens
      return nil unless total_tokens.positive?

      format_stats_tokens(total_tokens, context_pct)
    end

    def format_stats_tokens(total, context_pct)
      line = "#{format_number(total)} tokens"
      line += format(" · %.0f%% context", context_pct) if context_pct
      line
    end

    def log_session_stats(stats, thread_id)
      summary = stats.format_summary("Thread #{thread_id[0..7]} complete")
      log(:info, summary)
    end

    def process_next_queued(thread_id)
      next_text = @app_state.message_queue.dequeue(thread_id)
      return unless next_text

      msg = UserMessage.new(thread_id: thread_id, text: next_text, channel_id: nil, sender_name: nil)
      process_message(msg)
    end

    def find_thread_for_question(tool_use_id)
      @question_threads[tool_use_id]
    end

    def stop_active_response(thread_id)
      response = @active_responses.delete(thread_id)
      response&.stop_typing
      @app_state.message_queue.dequeue(thread_id)
    end

    def cleanup_failed_send(response, thread_id)
      response&.stop_typing
      @active_responses.delete(thread_id)
      @app_state.message_queue.release(thread_id)
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
          stop_if_idle(thread_id, persisted)
        end
      end

      def stop_if_idle(thread_id, persisted)
        return if persisted.is_paused

        idle_seconds = seconds_since_activity(persisted.last_activity_at)
        return unless idle_seconds
        return unless idle_seconds > IDLE_TIMEOUT

        log(:info, "Stopping idle session for thread #{thread_id[0..7]} (idle #{(idle_seconds / 60).round}min)")
        @session_manager.stop_session(thread_id)
      end

      def seconds_since_activity(last_activity_at)
        return nil unless last_activity_at

        Time.now - Time.parse(last_activity_at)
      end
    end

    include IdleManagement
  end
end
