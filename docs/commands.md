# Commands

All commands start with `!` and are sent as regular messages in a Mattermost thread. Commands are handled directly by EARL without being forwarded to Claude.

## Command Reference

| Command | Description |
|---------|-------------|
| `!help` | Show the help table |
| `!stats` (or `!cost`) | Show session stats (tokens, context, cost) |
| `!usage` | Show Claude Pro subscription usage limits |
| `!context` | Show context window usage for current session |
| `!stop` | Kill current session |
| `!escape` | Send SIGINT to Claude (interrupt mid-response) |
| `!kill` | Force kill session (SIGKILL) |
| `!compact` | Compact Claude's context |
| `!cd <path>` | Set working directory for next session |
| `!permissions` | Show current permission mode |
| `!heartbeats` | Show heartbeat schedule status |

## Command Details

### !help

Displays the command reference table in the thread.

### !stats

Shows token usage and cost for the current session.

**Active session output:**
```
#### :bar_chart: Session Stats
| Metric | Value |
|--------|-------|
| **Total tokens** | 15,234 (in: 12,000, out: 3,234) |
| **Context used** | 42.1% of 200,000 |
| **Model** | `claude-sonnet-4-5-20250929` |
| **Last TTFT** | 1.2s |
| **Last speed** | 85 tok/s |
| **Cost** | $0.0456 |
```

If no active session exists but persisted stats are available, shows a "(stopped)" variant with total tokens and cost.

### !usage

Fetches Claude Pro subscription usage data. Runs asynchronously (takes ~15s) and posts results when ready.

**Output:**
```
#### :bar_chart: Claude Pro Usage
- **Session:** 45% used — resets in 3h 22m
- **Week:** 12% used — resets Mon 9:00 AM
- **Extra:** 5% used ($2.50 / $50.00) — resets Feb 28
```

### !context

Fetches detailed context window usage for the current session. Runs asynchronously (takes ~20s).

**Output:**
```
#### :brain: Context Window Usage
- **Model:** `claude-sonnet-4-5-20250929`
- **Used:** 45,000 / 200,000 tokens (22.5%)

- **Messages:** 30,000 tokens (15.0%)
- **System prompt:** 5,000 tokens (2.5%)
- **System tools:** 8,000 tokens (4.0%)
- **Free space:** 155,000 tokens (77.5%)
```

Additional categories (Custom agents, Memory files, Skills, Autocompact buffer) appear when present in the session context.

### !stop

Kills the Claude process for the current thread and cleans up the session. Posts `:stop_sign: Session stopped.`

### !escape

Sends SIGINT to the Claude process, interrupting it mid-response. Useful when Claude is stuck or running an unwanted operation. Posts `:warning: Sent SIGINT to Claude.`

### !kill

Sends SIGKILL to force-kill the Claude process. Use when `!escape` doesn't work. Posts `:skull: Session force killed.` and cleans up the session.

### !compact

Passes through to Claude as the `/compact` slash command, triggering context compaction within the Claude session. This is routed through the normal message pipeline (not handled as a direct command).

### !cd \<path\>

Sets the working directory for the **next** new session in this thread. Does not affect the currently running session.

```
!cd ~/Code/myproject
```

Posts `:file_folder: Working directory set to /Users/you/Code/myproject (applies to next new session)`

Returns an error if the directory doesn't exist.

### !permissions

Shows the current permission mode. Permission mode is controlled via the `EARL_SKIP_PERMISSIONS` environment variable.

### !heartbeats

Shows a status table of all configured heartbeat schedules.

**Output:**
```
#### 🫀 Heartbeat Status
| Name | Next Run | Last Run | Runs | Status |
|------|----------|----------|------|--------|
| daily-standup | 2025-01-15 09:00 | 2025-01-14 09:00 | 5 | ⚪ Idle |
| ci-check | 2025-01-15 08:35 | 2025-01-15 08:30 | 42 | 🟢 Running |
```

Status indicators: 🟢 Running, 🔴 Error, ⚪ Idle
