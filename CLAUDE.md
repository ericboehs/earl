# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**EARL** (Engineering Assistant Relay for LLMs) is a Ruby CLI bot that connects to Mattermost via WebSocket, listens for messages in `#earl`, spawns Claude Code CLI sessions, and streams responses back as threaded replies.

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
- `EARL_CHANNEL_ID` — Channel to listen in
- `EARL_ALLOWED_USERS` — Comma-separated usernames allowed to interact

## Architecture

```
bin/earl                     # Entry point
lib/
  earl.rb                    # Module root, requires, shared logger
  earl/
    config.rb                # ENV-based configuration
    mattermost.rb            # WebSocket + REST API client
    claude_session.rb        # Single Claude CLI process wrapper
    session_manager.rb       # Maps thread IDs → Claude sessions
    runner.rb                # Main loop, wires everything together
```

### Message Flow

```
User posts in #earl
  → Mattermost WebSocket 'posted' event
  → Runner checks allowlist
  → SessionManager gets/creates ClaudeSession for thread
  → session.send_message(text) writes JSON to Claude stdin
  → Claude stdout emits assistant event with response text
  → on_text callback: POST new reply (or PUT update with debounce)
  → on_complete callback: final PUT with complete text
  → User sees threaded reply in Mattermost
```

### Key Details

- **WebSocket events**: `data.post` is a nested JSON string requiring double-parse
- **Claude CLI**: spawned with `--input-format stream-json --output-format stream-json --verbose --session-id <uuid> --dangerously-skip-permissions`
- **Streaming**: first text chunk creates a POST, subsequent chunks do PUT with 300ms debounce
- **Sessions**: follow-up messages in same thread reuse the same Claude process (same context window)
- **Shutdown**: SIGINT × 2, then SIGTERM to kill Claude processes

## Development Commands

- `bin/ci` — Run full CI pipeline
- `rubocop` — Ruby style checking
- `rubocop -A` — Auto-fix style violations
- `bin/rails test` — Run test suite

## Commit Messages

This project follows [Conventional Commits](https://www.conventionalcommits.org/) specification.
