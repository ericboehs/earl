# EARL Documentation

**EARL** (Engineering Assistant Relay for LLMs) is a Ruby CLI bot that connects to Mattermost via WebSocket, listens for messages in configured channels, spawns Claude Code CLI sessions, and streams responses back as threaded replies.

## Quick Start

```bash
# Set required environment variables (see configuration.md)
export MATTERMOST_URL="https://mattermost.example.com"
export MATTERMOST_BOT_TOKEN="your-bot-token"
export MATTERMOST_BOT_ID="your-bot-user-id"
export EARL_CHANNEL_ID="default-channel-id"
export EARL_ALLOWED_USERS="alice,bob"

# For multi-channel support, use EARL_CHANNELS instead of EARL_CHANNEL_ID
# See configuration.md for details

# Start EARL
ruby bin/earl
```

## Reference

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | System diagram, file tree, message flow, and design patterns |
| [Commands](commands.md) | All `!commands` with usage and examples |
| [Configuration](configuration.md) | Environment variables, config files, and YAML schemas |
| [Permissions](permissions.md) | MCP permission server, approval flow, and emoji mapping |
| [Memory](memory.md) | Persistent memory system, MCP tools, and file formats |
| [Heartbeats](heartbeats.md) | Scheduled tasks with cron, interval, and one-shot schedules |
| [Sessions](sessions.md) | Session lifecycle, persistence, resume, and idle timeout |
| [Streaming](streaming.md) | Response streaming, debouncing, tool display, and AskUserQuestion |

## Development

```bash
bin/ci            # Run full CI pipeline
rubocop           # Ruby style checking
rubocop -A        # Auto-fix style violations
bin/rails test    # Run test suite
```
