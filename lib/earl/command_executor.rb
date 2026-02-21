# frozen_string_literal: true

require "open3"
require "shellwords"

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

    HELP_TABLE = <<~HELP
      | Command | Description |
      |---------|-------------|
      | `!help` | Show this help table |
      | `!stats` | Show session stats (tokens, context, cost) |
      | `!usage` | Show Claude Pro subscription usage limits |
      | `!context` | Show context window usage for current session |
      | `!stop` | Kill current session |
      | `!escape` | Send SIGINT to Claude (interrupt) |
      | `!kill` | Force kill session |
      | `!compact` | Compact Claude's context |
      | `!cd <path>` | Set working directory for next session |
      | `!permissions` | Show current permission mode |
      | `!heartbeats` | Show heartbeat schedule status |
      | `!sessions` | List all tmux sessions |
      | `!session <name>` | Capture and show tmux pane output |
      | `!session <name> status` | AI-summarize session state |
      | `!session <name> kill` | Kill tmux session |
      | `!session <name> nudge` | Send nudge message to session |
      | `!session <name> approve` | Approve pending permission |
      | `!session <name> deny` | Deny pending permission |
      | `!session <name> "text"` | Send input to tmux session |
      | `!restart` | Restart EARL (pulls latest code in prod) |
      | `!spawn "prompt" [--name N] [--dir D]` | Spawn Claude in a new tmux session |
    HELP

    # Commands that pass through to Claude as slash commands.
    PASSTHROUGH_COMMANDS = { compact: "/compact" }.freeze

    # Maps command names to handler method symbols.
    DISPATCH = {
      help: :handle_help, stats: :handle_stats, stop: :handle_stop,
      escape: :handle_escape, kill: :handle_kill, cd: :handle_cd,
      permissions: :handle_permissions, heartbeats: :handle_heartbeats,
      usage: :handle_usage, context: :handle_context,
      sessions: :handle_sessions, session_show: :handle_session_show,
      session_status: :handle_session_status, session_kill: :handle_session_kill,
      session_nudge: :handle_session_nudge, session_approve: :handle_session_approve,
      session_deny: :handle_session_deny, session_input: :handle_session_input,
      restart: :handle_restart,
      spawn: :handle_spawn
    }.freeze

    USAGE_SCRIPT = File.expand_path("../../bin/claude-usage", __dir__)
    CONTEXT_SCRIPT = File.expand_path("../../bin/claude-context", __dir__)

    def initialize(session_manager:, mattermost:, config:, **extras)
      heartbeat_scheduler, tmux_store, tmux_adapter, runner = extras.values_at(:heartbeat_scheduler, :tmux_store, :tmux_adapter, :runner)
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

    def handle_restart(ctx)
      reply(ctx, ":arrows_counterclockwise: Restarting EARL...")
      @deps.runner&.request_restart
    end

    def handle_permissions(ctx)
      reply(ctx, "Permission mode is controlled via `EARL_SKIP_PERMISSIONS` env var.")
    end

    def handle_stats(ctx)
      thread_id = ctx.thread_id
      manager = @deps.session_manager
      session = manager.get(thread_id)
      if session
        reply(ctx, format_stats(session.stats))
        return
      end

      persisted = manager.persisted_session_for(thread_id)
      if persisted&.total_cost
        reply(ctx, format_persisted_stats(persisted))
      else
        reply(ctx, "No active session for this thread.")
      end
    end

    def handle_stop(ctx)
      @deps.session_manager.stop_session(ctx.thread_id)
      reply(ctx, ":stop_sign: Session stopped.")
    end

    def handle_escape(ctx)
      session = @deps.session_manager.get(ctx.thread_id)
      if session&.process_pid
        Process.kill("INT", session.process_pid)
        reply(ctx, ":warning: Sent SIGINT to Claude.")
      else
        reply(ctx, "No active session to interrupt.")
      end
    rescue Errno::ESRCH
      reply(ctx, "Process already exited.")
    end

    def handle_kill(ctx)
      session = @deps.session_manager.get(ctx.thread_id)
      if session&.process_pid
        Process.kill("KILL", session.process_pid)
        cleanup_and_reply(ctx, ":skull: Session force killed.")
      else
        reply(ctx, "No active session to kill.")
      end
    rescue Errno::ESRCH
      cleanup_and_reply(ctx, "Process already exited, session cleaned up.")
    end

    def handle_cd(ctx)
      cleaned = ctx.arg.to_s.strip
      if cleaned.empty?
        reply(ctx, ":x: Usage: `!cd <path>`")
        return
      end

      expanded = File.expand_path(cleaned)
      if Dir.exist?(expanded)
        @working_dirs[ctx.thread_id] = expanded
        reply(ctx, ":file_folder: Working directory set to `#{expanded}` (applies to next new session)")
      else
        reply(ctx, ":x: Directory not found: `#{expanded}`")
      end
    end

    def reply(ctx, message)
      @deps.mattermost.create_post(**ctx.post_params(message))
    end

    def cleanup_and_reply(ctx, message)
      @deps.session_manager.stop_session(ctx.thread_id)
      reply(ctx, message)
    end
  end
end
