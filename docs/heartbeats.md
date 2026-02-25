---
title: Heartbeats
nav_order: 7
---

# Heartbeats

Heartbeats are scheduled tasks that let EARL proactively perform work without waiting for a user message. Each heartbeat spawns a Claude session on a schedule, posts results to a configured Mattermost channel.

## YAML Configuration

Heartbeats are defined in `~/.config/earl/heartbeats.yml`:

```yaml
heartbeats:
  daily-standup:
    description: "Daily standup summary"
    schedule:
      cron: "0 9 * * 1-5"     # Weekdays at 9am
    channel_id: "abc123"
    working_dir: "~/Code/myproject"
    prompt: "Summarize yesterday's git commits and open PRs"
    permission_mode: auto       # auto or interactive
    persistent: false           # Reuse session across runs?
    timeout: 600                # Max seconds to wait (default: 600)
    enabled: true               # Active? (default: true)
    once: false                 # Auto-disable after first run? (default: false)
```

### Field Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `description` | string | no | heartbeat name | Human-readable description |
| `schedule` | object | yes | — | Schedule definition (see below) |
| `channel_id` | string | yes | — | Mattermost channel ID for results |
| `working_dir` | string | no | none | Working directory for the Claude session |
| `prompt` | string | yes | — | Prompt sent to Claude when heartbeat fires |
| `permission_mode` | string | no | `interactive` | `auto` (no approval) or `interactive` (emoji approval) |
| `persistent` | boolean | no | `false` | Reuse the same Claude session across runs |
| `timeout` | integer | no | `600` | Maximum seconds to wait for completion |
| `enabled` | boolean | no | `true` | Whether the heartbeat is active |
| `once` | boolean | no | `false` | Auto-disable after first execution |

## Schedule Types

### Cron

Standard 5-field cron expression: `minute hour day-of-month month day-of-week`

```yaml
schedule:
  cron: "0 9 * * 1-5"    # Weekdays at 9am
```

Supported syntax:
- `*` — all values
- `5` — specific value
- `1-5` — range
- `*/15` — step (every 15)
- `1,3,5` — list
- `1-5/2` — range with step

### Interval

Run every N seconds:

```yaml
schedule:
  interval: 3600    # Every hour
```

### One-Shot (run_at)

Run once at a specific Unix timestamp:

```yaml
schedule:
  run_at: 1769529600    # 2026-01-27 16:00:00 UTC

once: true               # Auto-disable after execution
```

## Execution Flow

1. Scheduler thread checks every 30 seconds for heartbeats due to run
2. Creates a header post in the configured channel: `🫀 **Daily standup summary**`
3. Spawns a Claude session (new or resumed if `persistent: true`)
4. Sends the prompt to Claude
5. Streams Claude's response as a threaded reply under the header post
6. On completion, schedules the next run

### Overlap Protection

A heartbeat won't fire again if its previous run is still active. The scheduler skips heartbeats where `running == true`.

### One-Off Tasks

Heartbeats with `once: true` are automatically disabled in the YAML file after execution (sets `enabled: false`). Combine with `run_at` for scheduled one-shots. Note: when creating one-off tasks via the `manage_heartbeat` MCP tool without a schedule, `run_at` is auto-set to fire immediately. In YAML, a `schedule` block is always required — heartbeats without one are silently filtered out.

### Config Auto-Reload

The scheduler monitors the YAML file's modification time. Changes are picked up within 30 seconds without restarting EARL. New heartbeats are added, deleted ones removed, and existing definitions updated (unless currently running).

## Permission Modes

| Mode | Behavior |
|------|----------|
| `auto` | Claude runs with `--dangerously-skip-permissions` (no approval needed) |
| `interactive` | Uses MCP permission server; posts approval requests in the channel |

## Persistent Sessions

When `persistent: true`, the heartbeat reuses the same Claude session ID across runs. This preserves context between executions (e.g., a monitoring heartbeat that remembers previous checks). When `false` (default), each run starts a fresh session.

## MCP Tool: manage_heartbeat

Claude can manage heartbeat schedules via the `manage_heartbeat` MCP tool.

**Actions:** `list`, `create`, `update`, `delete`

**Input schema:**

| Field | Type | Description |
|-------|------|-------------|
| `action` | string | `list`, `create`, `update`, or `delete` (required) |
| `name` | string | Heartbeat name (required for create/update/delete) |
| `description` | string | Human-readable description |
| `cron` | string | Cron expression |
| `interval` | integer | Interval in seconds |
| `run_at` | integer | Unix timestamp for one-shot |
| `channel_id` | string | Mattermost channel ID |
| `working_dir` | string | Working directory |
| `prompt` | string | Prompt to send to Claude |
| `permission_mode` | string | `auto` or `interactive` |
| `persistent` | boolean | Reuse session across runs |
| `timeout` | integer | Max seconds |
| `enabled` | boolean | Active state |
| `once` | boolean | Auto-disable after run |

Changes are written to `~/.config/earl/heartbeats.yml` and picked up by the scheduler within 30 seconds.

## Example Configs

```yaml
heartbeats:
  # Recurring: check CI status every 30 minutes during work hours
  ci-check:
    description: "Check CI pipeline status"
    schedule:
      cron: "*/30 9-17 * * 1-5"
    channel_id: "abc123"
    working_dir: "~/Code/myproject"
    prompt: "Check the CI pipeline status and report any failures"
    permission_mode: auto
    timeout: 120

  # Recurring: daily summary with persistent session
  daily-digest:
    description: "Daily activity digest"
    schedule:
      cron: "0 17 * * 1-5"
    channel_id: "abc123"
    prompt: "Summarize today's git activity across all repos"
    permission_mode: auto
    persistent: true

  # One-shot: run once at a specific time
  deploy-reminder:
    description: "Remind about Friday deploy"
    schedule:
      run_at: 1769529600
    channel_id: "abc123"
    prompt: "Remind the team about the Friday deploy freeze"
    permission_mode: auto
    once: true
```
