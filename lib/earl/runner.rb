# frozen_string_literal: true

module Earl
  # Main event loop that connects Mattermost messages to Claude sessions,
  # managing per-thread message queuing, command parsing, question handling,
  # and streaming response delivery.
  class Runner
    include Logging
    include Formatting

    # Tracks runtime state: shutdown flag, restart intent, and per-thread message queue.
    AppState = Struct.new(:shutting_down, :pending_restart, :pending_update, :shutdown_thread, :message_queue,
                          :idle_checker_thread, keyword_init: true)

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
      @services = build_services
      wire_circular_deps
      @app_state = AppState.new(shutting_down: false, pending_restart: false, pending_update: false,
                                shutdown_thread: nil, message_queue: MessageQueue.new)
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

    def request_restart
      @app_state.pending_restart = true
      begin_shutdown { restart }
    end

    def request_update
      @app_state.pending_restart = true
      @app_state.pending_update = true
      begin_shutdown { restart }
    end

    include ServiceBuilder
    include Startup
    include Lifecycle
    include MessageHandling
    include ReactionHandling
    include ResponseLifecycle
    include IdleManagement
  end
end
