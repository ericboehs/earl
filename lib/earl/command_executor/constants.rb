# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Constants shared across CommandExecutor: help table, dispatch map, scripts.
    module Constants
      HELP_TABLE = <<~HELP
        | Command | Description |
        |---------|-------------|
        | `!help` | Show this help table |
        | `!stats` | Show session stats (tokens, context, cost) |
        | `!usage` | Show Claude subscription usage limits |
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
        | `!update` | Pull latest code + bundle install, then restart |
        | `!restart` | Restart EARL (pulls latest code in prod) |
        | `!spawn "prompt" [--name N] [--dir D]` | Spawn Claude in a new tmux session |
      HELP

      PASSTHROUGH_COMMANDS = { compact: "/compact" }.freeze

      DISPATCH = {
        help: :handle_help, stats: :handle_stats, stop: :handle_stop,
        escape: :handle_escape, kill: :handle_kill, cd: :handle_cd,
        permissions: :handle_permissions, heartbeats: :handle_heartbeats,
        usage: :handle_usage, context: :handle_context,
        sessions: :handle_sessions, session_show: :handle_session_show,
        session_status: :handle_session_status, session_kill: :handle_session_kill,
        session_nudge: :handle_session_nudge, session_approve: :handle_session_approve,
        session_deny: :handle_session_deny, session_input: :handle_session_input,
        update: :handle_update, restart: :handle_restart,
        spawn: :handle_spawn
      }.freeze

      USAGE_SCRIPT = File.expand_path("../../../bin/claude-usage", __dir__)
      CONTEXT_SCRIPT = File.expand_path("../../../bin/claude-context", __dir__)
    end
  end
end
