# frozen_string_literal: true

require "rbconfig"

module Earl
  # Main event loop that connects Mattermost messages to Claude sessions,
  # managing per-thread message queuing, command parsing, question handling,
  # and streaming response delivery.
  class Runner
    include Logging
    include Formatting

    # Tracks runtime state: shutdown flag, restart intent, and per-thread message queue.
    AppState = Struct.new(:shutting_down, :pending_restart, :shutdown_thread, :message_queue, :idle_checker_thread,
                          keyword_init: true)

    # Bundles user message parameters that travel together through message routing.
    UserMessage = Data.define(:thread_id, :text, :channel_id, :sender_name)

    # Groups injected service dependencies to keep ivar count low.
    Services = Struct.new(:config, :session_store, :session_manager, :mattermost,
                          :command_executor, :question_handler, :heartbeat_scheduler,
                          :tmux_store, :tmux_monitor, keyword_init: true)

    # Groups per-thread response tracking state.
    ResponseState = Struct.new(:question_threads, :active_responses, keyword_init: true)

    IDLE_CHECK_INTERVAL = 300 # 5 minutes
    IDLE_TIMEOUT = 1800 # 30 minutes

    def initialize
      config = Config.new
      session_store = SessionStore.new
      session_manager = SessionManager.new(config: config, session_store: session_store)
      mattermost = Mattermost.new(config)
      tmux_store = TmuxSessionStore.new

      @services = Services.new(
        config: config, session_store: session_store, session_manager: session_manager,
        mattermost: mattermost, tmux_store: tmux_store,
        heartbeat_scheduler: HeartbeatScheduler.new(
          config: config, mattermost: mattermost
        ),
        command_executor: CommandExecutor.new(
          session_manager: session_manager, mattermost: mattermost, config: config,
          heartbeat_scheduler: nil, tmux_store: tmux_store
        ),
        question_handler: QuestionHandler.new(mattermost: mattermost),
        tmux_monitor: TmuxMonitor.new(mattermost: mattermost, tmux_store: tmux_store)
      )
      # Wire circular deps into command_executor after both exist
      executor_deps = @services.command_executor.instance_variable_get(:@deps)
      executor_deps.heartbeat_scheduler = @services.heartbeat_scheduler
      executor_deps.runner = self
      @app_state = AppState.new(shutting_down: false, pending_restart: false, shutdown_thread: nil,
                                message_queue: MessageQueue.new)
      @responses = ResponseState.new(question_threads: {}, active_responses: {})

      configure_channels
    end

    def start
      setup_handlers
      ClaudeSession.cleanup_mcp_configs
      @services.session_manager.resume_all
      @services.tmux_store.cleanup!
      start_background_services
      @services.mattermost.connect
      log_startup
      sleep 0.5 until @app_state.shutting_down
      wait_and_exec_restart if @app_state.pending_restart
    end

    private

    def configure_channels
      channels = @services.config.channels
      @services.mattermost.configure_channels(Set.new(channels.keys)) if channels.size > 1
    end

    def log_startup
      config = @services.config
      channel_names = resolve_channel_names(config.channels.keys)
      count = channel_names.size
      log(:info, "EARL is running. Listening in #{count} channel#{'s' unless count == 1}: #{channel_names.join(', ')}")
      log(:info, "Allowed users: #{config.allowed_users.join(', ')}")
    end

    def resolve_channel_names(channel_ids)
      channel_ids.map do |id|
        info = @services.mattermost.get_channel(channel_id: id)
        info&.fetch("display_name", nil) || info&.fetch("name", nil) || id[0..7]
      end
    end

    def start_background_services
      start_idle_checker
      @services.heartbeat_scheduler.start
      @services.tmux_monitor.start
    end

    def setup_handlers
      setup_signal_handlers
      setup_message_handler
      setup_reaction_handler
    end

    def setup_signal_handlers
      %w[INT TERM].each { |signal| trap(signal) { handle_shutdown_signal } }
      trap("HUP") { handle_restart_signal }
    end

    def begin_shutdown(&action)
      return if @app_state.shutting_down

      @app_state.shutting_down = true
      @app_state.shutdown_thread = Thread.new(&action)
    end

    def handle_shutdown_signal
      begin_shutdown { shutdown }
    end

    def handle_restart_signal
      @app_state.pending_restart = true
      begin_shutdown { restart }
    end

    def shutdown
      log(:info, "Shutting down...")
      @app_state.idle_checker_thread&.kill
      @services.heartbeat_scheduler.stop
      @services.tmux_monitor.stop
      @services.session_manager.pause_all
      log(:info, "Goodbye!")
    end

    public

    def request_restart
      @app_state.pending_restart = true
      begin_shutdown { restart }
    end

    private

    def restart
      log(:info, "Restarting EARL...")
      pull_latest unless Earl.development?
      shutdown
    end

    def wait_and_exec_restart
      @app_state.shutdown_thread&.join
      cmd = restart_command
      log(:info, "Exec: #{cmd.join(' ')}")
      Bundler.with_unbundled_env { Kernel.exec(*cmd) }
    end

    def pull_latest
      Dir.chdir(File.dirname($PROGRAM_NAME)) do
        success = system("git", "pull", "--ff-only")
        log(success ? :info : :warn, "git pull --ff-only #{success ? 'succeeded' : 'failed (continuing with current code)'}")
      end
    rescue StandardError => error
      log(:warn, "git pull failed: #{error.message}")
    end

    def restart_command
      [ RbConfig.ruby, $PROGRAM_NAME ]
    end

    # Message routing: receives user messages, dispatches commands or enqueues for Claude.
    module MessageHandling
      private

      def setup_message_handler
        @services.mattermost.on_message do |sender_name:, thread_id:, text:, post_id:, channel_id:|
          if allowed_user?(sender_name)
            msg = UserMessage.new(thread_id: thread_id, text: text, channel_id: channel_id,
                                  sender_name: sender_name)
            handle_incoming_message(msg)
          end
        end
      end

      def handle_incoming_message(msg)
        text = msg.text
        thread_id = msg.thread_id
        channel_id = msg.channel_id
        if CommandParser.command?(text)
          command = CommandParser.parse(text)
          if command
            result = @services.command_executor.execute(command, thread_id: thread_id, channel_id: channel_id)
            if result&.dig(:passthrough)
              passthrough_msg = UserMessage.new(
                thread_id: thread_id, text: result[:passthrough],
                channel_id: channel_id, sender_name: msg.sender_name
              )
              enqueue_message(passthrough_msg)
            end
            stop_active_response(thread_id) if %i[stop kill].include?(command.name)
          end
        else
          enqueue_message(msg)
        end
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
        [ existing, session ]
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

    # Emoji reaction handling: routes reactions to question handler or tmux monitor.
    module ReactionHandling
      private

      def setup_reaction_handler
        @services.mattermost.on_reaction do |user_id:, post_id:, emoji_name:|
          handle_reaction(user_id: user_id, post_id: post_id, emoji_name: emoji_name)
        end
      end

      def handle_reaction(user_id:, post_id:, emoji_name:)
        return unless allowed_reactor?(user_id)

        result = @services.question_handler.handle_reaction(post_id: post_id, emoji_name: emoji_name)
        if result
          thread_id = @responses.question_threads[result[:tool_use_id]]
          return unless thread_id

          session = @services.session_manager.get(thread_id)
          session&.send_message(result[:answer_text])
          return
        end

        @services.tmux_monitor.handle_reaction(post_id: post_id, emoji_name: emoji_name)
      end

      def allowed_reactor?(user_id)
        allowed = @services.config.allowed_users
        return true if allowed.empty?

        username = @services.mattermost.get_user(user_id: user_id)["username"]
        return false unless username

        allowed.include?(username)
      end
    end

    # Streaming response lifecycle: creates responses, wires callbacks, handles completion.
    module ResponseLifecycle
      private

      def prepare_response(session, thread_id, channel_id)
        response = StreamingResponse.new(thread_id: thread_id, mattermost: @services.mattermost, channel_id: channel_id)
        @responses.active_responses[thread_id] = response
        response.start_typing
        setup_callbacks(session, response, thread_id)
        response
      end

      def setup_callbacks(session, response, thread_id)
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
        result = @services.question_handler.handle_tool_use(thread_id: thread_id, tool_use: tool_use, channel_id: channel_id)
        return unless result.is_a?(Hash)

        tool_use_id = result[:tool_use_id]
        @responses.question_threads[tool_use_id] = thread_id if tool_use_id
      end

      def handle_response_complete(thread_id)
        manager = @services.session_manager
        session = manager.get(thread_id)
        response = @responses.active_responses.delete(thread_id)

        if session && response
          stats = session.stats
          response.on_complete
          log_session_stats(stats, thread_id)
          manager.save_stats(thread_id)
        else
          log(:warn, "Completion for thread #{thread_id[0..7]} with missing session or response (likely killed)")
          response&.stop_typing
        end

        process_next_queued(thread_id)
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

    # Idle session management.
    module IdleManagement
      private

      def start_idle_checker
        @app_state.idle_checker_thread = Thread.new do
          loop do
            sleep IDLE_CHECK_INTERVAL
            check_idle_sessions
          rescue StandardError => error
            log(:error, "Idle checker error: #{error.message}")
          end
        end
      end

      def check_idle_sessions
        @services.session_store.load.each do |thread_id, persisted|
          stop_if_idle(thread_id, persisted)
        end
      end

      def stop_if_idle(thread_id, persisted)
        return if persisted.is_paused

        idle_seconds = seconds_since_activity(persisted.last_activity_at)
        return unless idle_seconds
        return unless idle_seconds > IDLE_TIMEOUT

        log(:info, "Stopping idle session for thread #{thread_id[0..7]} (idle #{(idle_seconds / 60).round}min)")
        @services.session_manager.stop_session(thread_id)
      end

      def seconds_since_activity(last_activity_at)
        return nil unless last_activity_at

        Time.now - Time.parse(last_activity_at)
      end
    end

    include MessageHandling
    include ReactionHandling
    include ResponseLifecycle
    include IdleManagement
  end
end
