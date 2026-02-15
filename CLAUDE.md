# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**EARL** (Engineering Assistant Relay for LLMs) is a Ruby CLI bot that connects to Mattermost via WebSocket, listens for messages in configured channels, spawns Claude Code CLI sessions, and streams responses back as threaded replies.

This is a standalone CLI app — the Rails starter template provides Gemfile/test infrastructure but we don't use the web framework.

Reference implementation: `~/Code/anneschuth/claude-threads/` (TypeScript/Bun).

## Running

```bash
ruby bin/earl
```

Requires env vars (see `.envrc`):
- `MATTERMOST_URL` — Mattermost server URL
- `MATTERMOST_BOT_TOKEN` — Bot authentication token
- `MATTERMOST_BOT_ID` — Bot user ID (to ignore own messages)
- `EARL_CHANNEL_ID` — Default channel to listen in
- `EARL_CHANNELS` — Multi-channel config (comma-separated `channel_id:/working/dir` pairs, e.g. `chan1:/path1,chan2:/path2`)
- `EARL_ALLOWED_USERS` — Comma-separated usernames allowed to interact
- `EARL_SKIP_PERMISSIONS` — Set to `true` to use `--dangerously-skip-permissions` instead of MCP approval

Optional config files:
- `~/.config/earl/heartbeats.yml` — Heartbeat schedule definitions
- `~/.config/earl/memory/` — Persistent memory files (SOUL.md, USER.md, daily notes)
- `~/.config/earl/sessions.json` — Session persistence store
- `~/.config/earl/allowed_tools/` — Per-thread tool approval lists

## Architecture

```
bin/earl                          # Entry point
bin/earl-permission-server        # MCP permission server (spawned by Claude CLI as subprocess)
bin/claude-context                # Context window usage helper (spawned by !context command)
bin/claude-usage                  # Claude Pro usage helper (spawned by !usage command)
lib/
  earl.rb                         # Module root, requires, shared logger
  earl/
    config.rb                     # ENV-based configuration
    logging.rb                    # Shared logging mixin
    formatting.rb                 # Shared number formatting helpers
    permission_config.rb          # Shared permission env builder
    tool_input_formatter.rb       # Shared tool display formatting
    mattermost.rb                 # WebSocket + REST API client
    mattermost/api_client.rb      # HTTP client with retry logic
    claude_session.rb             # Single Claude CLI process wrapper
    session_manager.rb            # Maps thread IDs -> Claude sessions
    session_store.rb              # Persists session metadata to disk
    streaming_response.rb         # Mattermost post lifecycle (create/update/debounce)
    message_queue.rb              # Per-thread message queuing for busy sessions
    command_parser.rb             # Parses !commands from message text
    command_executor.rb           # Executes !help, !stats, !stop, !kill, !escape, !compact, !cd, !permissions, !heartbeats, !usage, !context
    question_handler.rb           # AskUserQuestion tool -> emoji reaction flow
    runner.rb                     # Main event loop, wires everything together
    cron_parser.rb                # Minimal 5-field cron expression parser
    heartbeat_config.rb           # Loads heartbeat definitions from YAML
    heartbeat_scheduler.rb        # Runs heartbeat tasks on cron/interval/one-shot schedules; auto-reloads config
    mcp/
      config.rb                   # MCP server ENV-based config
      server.rb                   # JSON-RPC 2.0 MCP server over stdio
      approval_handler.rb         # Permission approval via Mattermost reactions
      memory_handler.rb           # save_memory / search_memory MCP tools
      heartbeat_handler.rb        # manage_heartbeat MCP tool (CRUD heartbeat schedules)
    memory/
      store.rb                    # File I/O for persistent memory (markdown files)
      prompt_builder.rb           # Builds system prompt from memory store
```

### Message Flow

```
User posts in channel
  -> Mattermost WebSocket 'posted' event
  -> Runner checks allowlist
  -> CommandParser checks for !commands
     -> If command: CommandExecutor handles it (!help, !stats, !kill, !cd, etc.)
     -> If message: MessageQueue serializes per-thread
  -> SessionManager gets/creates ClaudeSession for thread
     -> Resumes from session store if available
     -> Builds MCP config for permission approval
     -> Injects memory context via --append-system-prompt
  -> session.send_message(text) writes JSON to Claude stdin
  -> Claude stdout emits events (assistant, result, system)
     -> on_text: StreamingResponse creates POST or debounced PUT
     -> on_tool_use: StreamingResponse shows tool icon + detail
     -> on_tool_use(AskUserQuestion): QuestionHandler posts options, waits for reaction
     -> on_complete: final PUT with stats footer, process next queued message
  -> User sees threaded reply in Mattermost
```

### Key Details

- **WebSocket events**: `data.post` is a nested JSON string requiring double-parse
- **Claude CLI**: spawned with `--input-format stream-json --output-format stream-json --verbose`
- **Permissions**: Default uses `--permission-prompt-tool mcp__earl__permission_prompt --mcp-config <path>` for interactive approval via Mattermost reactions. Set `EARL_SKIP_PERMISSIONS=true` for `--dangerously-skip-permissions`.
- **Streaming**: first text chunk creates a POST, subsequent chunks do PUT with 300ms debounce
- **Sessions**: follow-up messages in same thread reuse the same Claude process (same context window)
- **Session persistence**: sessions are saved to `~/.config/earl/sessions.json` and resumed on restart
- **Shutdown**: SIGINT sends INT to Claude process, waits ~2s, then TERM. Runner calls `pause_all` to persist sessions before exit.
- **Memory**: Persistent facts stored as markdown in `~/.config/earl/memory/`. Injected into Claude sessions via `--append-system-prompt`. Claude can save/search via MCP tools.
- **Heartbeats**: Scheduled tasks (cron/interval/one-shot via `run_at`) that spawn Claude sessions, posting results to configured channels. One-off tasks (`once: true`) auto-disable after execution. Config auto-reloads on file change. Claude can manage schedules via the `manage_heartbeat` MCP tool.

## Testing with Mattermost MCP

A Mattermost MCP server is configured in `.mcp.json` (gitignored), authenticated as `@eric`. This lets you interact with EARL as a real user for integration testing while EARL is running (`ruby bin/earl`).

**Available tools:** `mcp__mattermost__send_message`, `mcp__mattermost__get_channel_messages`, `mcp__mattermost__search_messages`, `mcp__mattermost__list_channels`, etc.

**Key IDs:**
- EARL channel: `bt36n3e7qj837qoi1mmho54xhh`
- Eric's user ID: `ip5xzirtgf8ebe1xrt4nngxwty`
- Bot user ID: `x1pomjhc9f8xjx7nwj1o6s33gc`

**Example workflow — send a message and check EARL's reply:**
```
# Send a message to EARL (starts a new thread)
mcp__mattermost__send_message(channel_id: "bt36n3e7qj837qoi1mmho54xhh", message: "Hello EARL")

# Or reply in an existing thread
mcp__mattermost__send_message(channel_id: "bt36n3e7qj837qoi1mmho54xhh", message: "!usage", reply_to: "<root_post_id>")

# Read recent messages to see EARL's response
mcp__mattermost__get_channel_messages(channel_id: "bt36n3e7qj837qoi1mmho54xhh", limit: 5)
```

## Development Commands

- `bin/ci` — Run full CI pipeline
- `rubocop` — Ruby style checking
- `rubocop -A` — Auto-fix style violations
- `bin/rails test` — Run test suite

## Commit Messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/) specification.
