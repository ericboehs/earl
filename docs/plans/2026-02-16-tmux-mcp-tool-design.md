# Tmux Session MCP Tool Design

## Overview

Add a `manage_tmux_sessions` MCP tool so EARL-spawned Claude sessions can programmatically interact with other Claude sessions running in tmux. This turns any Claude session into a potential supervisor — listing sessions, checking status, approving permissions, sending input, spawning workers, and killing sessions.

## Tool Definition

Single tool: `manage_tmux_sessions` with an `action` parameter (consistent with `manage_heartbeat`).

### Actions

| Action | Required Args | Optional Args | Description |
|--------|--------------|---------------|-------------|
| `list` | — | — | List all tmux panes running Claude |
| `capture` | `target` | `lines` | Capture last N lines of pane output (default 100) |
| `status` | `target` | — | Capture last 200 lines for Claude to summarize |
| `approve` | `target` | — | Press Enter on a permission dialog |
| `deny` | `target` | — | Press Escape on a permission dialog |
| `send_input` | `target`, `text` | — | Send text to a pane |
| `spawn` | `prompt` | `name`, `working_dir` | Spawn new Claude tmux session (requires Mattermost confirmation) |
| `kill` | `target` | — | Kill a tmux session |

The `target` parameter accepts a tmux pane target (e.g., `session:window.pane`).

## Architecture

### New File

`lib/earl/mcp/tmux_handler.rb` — `Earl::Mcp::TmuxHandler`

Follows the MCP handler interface: `tool_definitions`, `handles?`, `call`.

### Dependencies (constructor-injected)

- `tmux_adapter` — `Tmux` module (default), for all tmux operations
- `tmux_store` — `TmuxSessionStore` instance, for spawn persistence
- `config` — `Mcp::Config`, for Mattermost channel/thread/bot IDs and WebSocket URL
- `api_client` — `Mattermost::ApiClient`, for posting spawn confirmation + reactions

### Wiring

In `bin/earl-permission-server`:

```ruby
tmux_store = Earl::TmuxSessionStore.new
tmux_handler = Earl::Mcp::TmuxHandler.new(
  config: config, api_client: api_client, tmux_store: tmux_store
)

server = Earl::Mcp::Server.new(
  handlers: [approval_handler, memory_handler, heartbeat_handler, tmux_handler]
)
```

## Spawn Confirmation Flow

When `action: spawn` is called:

1. Validate args (prompt required, name must not contain `.`/`:`, check `session_exists?`)
2. Post confirmation to Mattermost: `:rocket: **Spawn Request** ...` with reaction options
3. Wait for user reaction via WebSocket (same timeout as permission approval)
4. On approve: create tmux session, save to TmuxSessionStore, return success
5. On deny: return denial message
6. Clean up confirmation post

## Error Handling

- **tmux not installed:** Return "tmux is not available" for all actions
- **Invalid target:** Catch `Tmux::NotFound`, return "Session/pane not found"
- **Spawn name conflicts:** Check `session_exists?` before posting confirmation, fail early
- **Spawn timeout:** Same timeout as permission approval, return denial on timeout
- **General tmux errors:** Catch `Tmux::Error`, return error message text

## Testing

`test/lib/earl/mcp/tmux_handler_test.rb` — inject mock tmux adapter (same DI pattern as `command_executor_test.rb`).
