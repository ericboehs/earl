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
    CommandContext = Data.define(:thread_id, :channel_id, :arg, :args)

    # Groups injected dependencies to keep ivar count low.
    Deps = Struct.new(:session_manager, :mattermost, :config, :heartbeat_scheduler,
                      :tmux_store, :tmux, keyword_init: true)

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
      | `!spawn "prompt" [--name N] [--dir D]` | Spawn Claude in a new tmux session |
    HELP

    # Commands that pass through to Claude as slash commands.
    PASSTHROUGH_COMMANDS = { compact: "/compact" }.freeze

    USAGE_SCRIPT = File.expand_path("../../bin/claude-usage", __dir__)
    CONTEXT_SCRIPT = File.expand_path("../../bin/claude-context", __dir__)

    def initialize(session_manager:, mattermost:, config:, heartbeat_scheduler: nil, tmux_store: nil, tmux_adapter: Tmux)
      @deps = Deps.new(
        session_manager: session_manager, mattermost: mattermost, config: config,
        heartbeat_scheduler: heartbeat_scheduler, tmux_store: tmux_store, tmux: tmux_adapter
      )
      @working_dirs = {} # thread_id -> path
    end

    # Returns { passthrough: "/command" } for passthrough commands so the
    # runner can route them through the normal message pipeline.
    # Returns nil for all other commands (handled inline).
    def execute(command, thread_id:, channel_id:)
      slash = PASSTHROUGH_COMMANDS[command.name]
      return { passthrough: slash } if slash

      ctx = CommandContext.new(
        thread_id: thread_id, channel_id: channel_id,
        arg: command.args.first, args: command.args
      )
      dispatch_command(command.name, ctx)
      nil
    end

    def working_dir_for(thread_id)
      @working_dirs[thread_id]
    end

    private

    def dispatch_command(name, ctx)
      case name
      when :help then handle_help(ctx)
      when :stats then handle_stats(ctx)
      when :stop then handle_stop(ctx)
      when :escape then handle_escape(ctx)
      when :kill then handle_kill(ctx)
      when :cd then handle_cd(ctx)
      when :permissions then reply(ctx, "Permission mode is controlled via `EARL_SKIP_PERMISSIONS` env var.")
      when :heartbeats then handle_heartbeats(ctx)
      when :usage then handle_usage(ctx)
      when :context then handle_context(ctx)
      when :sessions then handle_sessions(ctx)
      when :session_show then handle_session_show(ctx)
      when :session_status then handle_session_status(ctx)
      when :session_kill then handle_session_kill(ctx)
      when :session_nudge then handle_session_nudge(ctx)
      when :session_approve then handle_session_approve(ctx)
      when :session_deny then handle_session_deny(ctx)
      when :session_input then handle_session_input(ctx)
      when :spawn then handle_spawn(ctx)
      end
    end

    def handle_help(ctx)
      reply(ctx, HELP_TABLE)
    end

    def handle_stats(ctx)
      session = @deps.session_manager.get(ctx.thread_id)
      if session
        reply(ctx, format_stats(session.stats))
        return
      end

      persisted = @deps.session_manager.persisted_session_for(ctx.thread_id)
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
      @deps.mattermost.create_post(channel_id: ctx.channel_id, message: message, root_id: ctx.thread_id)
    end

    def cleanup_and_reply(ctx, message)
      @deps.session_manager.stop_session(ctx.thread_id)
      reply(ctx, message)
    end
  end
end
