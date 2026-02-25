# frozen_string_literal: true

module Earl
  class Runner
    # Constructs and wires together the service dependency graph.
    module ServiceBuilder
      private

      def build_services
        core = build_core_services
        assemble_services(core)
      end

      def build_core_services
        config = Config.new
        session_store = SessionStore.new
        mattermost = Mattermost.new(config)
        { config: config, session_store: session_store, mattermost: mattermost,
          tmux_store: TmuxSessionStore.new,
          session_manager: SessionManager.new(config: config, session_store: session_store) }
      end

      def assemble_services(core)
        config, mattermost, tmux_store = core.values_at(:config, :mattermost, :tmux_store)
        Services.new(
          **core,
          heartbeat_scheduler: HeartbeatScheduler.new(config: config, mattermost: mattermost),
          command_executor: build_command_executor(core),
          question_handler: QuestionHandler.new(mattermost: mattermost),
          tmux_monitor: TmuxMonitor.new(mattermost: mattermost, tmux_store: tmux_store)
        )
      end

      def build_command_executor(core)
        CommandExecutor.new(
          session_manager: core[:session_manager], mattermost: core[:mattermost],
          config: core[:config], heartbeat_scheduler: nil, tmux_store: core[:tmux_store]
        )
      end

      def wire_circular_deps
        executor_deps = @services.command_executor.instance_variable_get(:@deps)
        executor_deps.heartbeat_scheduler = @services.heartbeat_scheduler
        executor_deps.runner = self
      end
    end
  end
end
