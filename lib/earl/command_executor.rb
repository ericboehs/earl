# frozen_string_literal: true

require "open3"
require "shellwords"

require_relative "command_executor/constants"
require_relative "command_executor/lifecycle_handler"
require_relative "command_executor/session_handler"
require_relative "command_executor/spawn_handler"
require_relative "command_executor/stats_formatter"
require_relative "command_executor/usage_handler"
require_relative "command_executor/heartbeat_display"

module Earl
  # Executes `!` commands parsed by CommandParser, dispatching to the
  # appropriate session manager or mattermost action.
  class CommandExecutor
    include Logging
    include Formatting
    include Constants
    include LifecycleHandler
    include SessionHandler
    include SpawnHandler
    include StatsFormatter
    include UsageHandler
    include HeartbeatDisplay

    # Bundles dispatch context so thread_id + channel_id don't travel as separate args.
    CommandContext = Data.define(:thread_id, :channel_id, :arg, :args) do
      def post_params(message)
        { channel_id: channel_id, message: message, root_id: thread_id }
      end
    end

    # Groups injected dependencies to keep ivar count low.
    Deps = Struct.new(:session_manager, :mattermost, :config, :heartbeat_scheduler,
                      :tmux_store, :tmux, :runner, keyword_init: true)

    def initialize(session_manager:, mattermost:, config:, **extras)
      heartbeat_scheduler, tmux_store, tmux_adapter, runner = extras.values_at(:heartbeat_scheduler, :tmux_store,
                                                                               :tmux_adapter, :runner)
      @deps = Deps.new(
        session_manager: session_manager, mattermost: mattermost, config: config,
        heartbeat_scheduler: heartbeat_scheduler, tmux_store: tmux_store, tmux: tmux_adapter || Tmux, runner: runner
      )
      @working_dirs = {} # thread_id -> path
    end

    # Returns { passthrough: "/command" } for passthrough commands so the
    # runner can route them through the normal message pipeline.
    # Returns nil for all other commands (handled inline).
    def execute(command, thread_id:, channel_id:)
      cmd_name = command.name
      slash = PASSTHROUGH_COMMANDS[cmd_name]
      return { passthrough: slash } if slash

      ctx = build_context(command, thread_id, channel_id)
      dispatch_command(cmd_name, ctx)
      nil
    end

    def working_dir_for(thread_id)
      @working_dirs[thread_id]
    end

    private

    def dispatch_command(name, ctx)
      handler = DISPATCH[name]
      send(handler, ctx) if handler
    end

    def build_context(command, thread_id, channel_id)
      cmd_args = command.args
      CommandContext.new(thread_id: thread_id, channel_id: channel_id, arg: cmd_args.first, args: cmd_args)
    end

    def handle_help(ctx)
      reply(ctx, HELP_TABLE)
    end

    def handle_update(ctx)
      reply(ctx, ":arrows_counterclockwise: Updating EARL...")
      save_restart_context(ctx, "update")
      @deps.runner&.request_update
    end

    def handle_restart(ctx)
      reply(ctx, ":arrows_counterclockwise: Restarting EARL...")
      save_restart_context(ctx, "restart")
      @deps.runner&.request_restart
    end

    def save_restart_context(ctx, command)
      config_dir = Earl.config_root
      FileUtils.mkdir_p(config_dir)
      path = File.join(config_dir, "restart_context.json")
      data = ctx.deconstruct_keys(%i[channel_id thread_id]).merge(command: command)
      File.write(path, JSON.generate(data))
    rescue StandardError => error
      log(:warn, "Failed to save restart context: #{error.message}")
    end

    def handle_permissions(ctx)
      reply(ctx, "Permission mode is controlled via `EARL_SKIP_PERMISSIONS` env var.")
    end

    def handle_stats(ctx)
      session = @deps.session_manager.get(ctx.thread_id)
      return reply(ctx, format_stats(session.stats)) if session

      reply_persisted_stats(ctx)
    end

    def reply_persisted_stats(ctx)
      persisted = @deps.session_manager.persisted_session_for(ctx.thread_id)
      if persisted&.total_cost
        reply(ctx, format_persisted_stats(persisted))
      else
        reply(ctx, "No active session for this thread.")
      end
    end

    def reply(ctx, message)
      @deps.mattermost.create_post(**ctx.post_params(message))
    end
  end
end
