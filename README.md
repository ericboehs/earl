# EARL

**Engineering Assistant Relay for LLMs** — a Ruby CLI bot that connects to Mattermost via WebSocket, listens for messages in configured channels, spawns Claude Code CLI sessions, and streams responses back as threaded replies.

## Installation

```bash
gem install earl-bot
```

Or add to your Gemfile:

```ruby
gem "earl-bot"
```

## Quick Start

```bash
# Configure environment
cp .envrc.example .envrc  # or use ~/.config/earl/env
# Fill in MATTERMOST_URL, MATTERMOST_BOT_TOKEN, etc.

# Run directly
earl

# Or install dev + prod environments
earl-install
```

## Running as a Service

EARL can run as a persistent service for automatic startup and crash recovery.

**Prerequisite:** [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) must be installed and authenticated.

```bash
earl-install
```

On first run this creates `~/.config/earl/env` — fill in your secrets and re-run. On subsequent runs it sets up config dirs, clones the prod repo, and creates a wrapper script.

## Features

- **Streaming responses** — first text chunk creates a post, subsequent chunks update via debounced PUT
- **Session persistence** — follow-up messages in the same thread reuse the same Claude context window; sessions survive restarts
- **Permission approval** — tool use is gated by Mattermost emoji reactions (or skip with `EARL_SKIP_PERMISSIONS=true`)
- **Memory** — persistent facts stored as markdown, injected into Claude sessions and manageable via MCP tools
- **Heartbeats** — scheduled tasks (cron/interval/one-shot) that spawn Claude sessions on a schedule
- **Tmux supervision** — Mattermost becomes a control plane for all running Claude sessions (EARL-managed and standalone)
- **Claude HOME isolation** — EARL's Claude sessions use an isolated config directory, separate from the user's personal `~/.claude/`

## Configuration

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `MATTERMOST_URL` | Mattermost server URL |
| `MATTERMOST_BOT_TOKEN` | Bot authentication token |
| `MATTERMOST_BOT_ID` | Bot user ID (to ignore own messages) |
| `EARL_CHANNEL_ID` | Default channel to listen in |
| `EARL_ALLOWED_USERS` | Comma-separated usernames allowed to interact |

### Optional

| Variable | Description |
|----------|-------------|
| `EARL_CHANNELS` | Multi-channel config (`channel_id:/working/dir` pairs) |
| `EARL_SKIP_PERMISSIONS` | Set to `true` to skip permission prompts |
| `EARL_CLAUDE_HOME` | Custom HOME for Claude subprocesses (default: `~/.config/earl/claude-home`) |
| `EARL_DEBUG` | Enable debug logging |

## Commands

Users can send commands in Mattermost messages:

| Command | Description |
|---------|-------------|
| `!help` | Show available commands |
| `!stats` | Show session statistics |
| `!stop` | Stop current response |
| `!kill` | Kill Claude session for this thread |
| `!compact` | Compact the session context |
| `!cd <path>` | Change working directory |
| `!sessions` | List all Claude sessions (EARL + tmux) |
| `!session <name> status/approve/deny` | Manage tmux sessions |
| `!spawn "prompt"` | Spawn a new Claude session in tmux |
| `!usage` | Show Claude usage |
| `!context` | Show context window usage |
| `!heartbeats` | List scheduled heartbeats |

## Development

```bash
bin/ci                # Full CI pipeline (rubocop + reek + tests + coverage)
rubocop -A            # Auto-fix style violations
bundle exec rake test # Run test suite
```

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## License

This project is licensed under the [MIT License](LICENSE).
