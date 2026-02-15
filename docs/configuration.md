# Configuration

## Required Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `MATTERMOST_URL` | Mattermost server URL | `https://mattermost.example.com` |
| `MATTERMOST_BOT_TOKEN` | Bot authentication token | `abc123...` |
| `MATTERMOST_BOT_ID` | Bot user ID (used to ignore own messages) | `x1pomjhc9f8xjx7nwj1o6s33gc` |
| `EARL_CHANNEL_ID` | Default channel to listen in | `bt36n3e7qj837qoi1mmho54xhh` |

## Optional Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `EARL_CHANNELS` | Multi-channel config (comma-separated `channel_id:/working/dir` pairs) | Uses `EARL_CHANNEL_ID` with `Dir.pwd` |
| `EARL_ALLOWED_USERS` | Comma-separated usernames allowed to interact | Empty (all users allowed — no access restriction) |
| `EARL_SKIP_PERMISSIONS` | Set to `true` to use `--dangerously-skip-permissions` | `false` |

### EARL_CHANNELS Format

```bash
# Single channel with working directory
EARL_CHANNELS="chan1:/home/user/project-a"

# Multiple channels
EARL_CHANNELS="chan1:/home/user/project-a,chan2:/home/user/project-b"

# Channel without explicit directory (uses current working directory)
EARL_CHANNELS="chan1"
```

If `EARL_CHANNELS` is not set, EARL listens on `EARL_CHANNEL_ID` using the current working directory.

## Config Files

| Path | Format | Description |
|------|--------|-------------|
| `~/.config/earl/sessions.json` | JSON | Session persistence store (auto-managed) |
| `~/.config/earl/heartbeats.yml` | YAML | Heartbeat schedule definitions |
| `~/.config/earl/memory/` | Markdown | Persistent memory files |
| `~/.config/earl/memory/SOUL.md` | Markdown | EARL's personality and boundaries |
| `~/.config/earl/memory/USER.md` | Markdown | User preferences and identity |
| `~/.config/earl/memory/YYYY-MM-DD.md` | Markdown | Daily episodic memory entries |
| `~/.config/earl/allowed_tools/` | JSON | Per-thread tool approval lists |
| `~/.config/earl/allowed_tools/<thread_id>.json` | JSON | Array of tool names approved for a thread |

## MCP Server Environment Variables

These are set automatically by EARL when spawning the MCP permission server. Listed here for reference.

| Variable | Description |
|----------|-------------|
| `PLATFORM_URL` | Mattermost server URL (from `MATTERMOST_URL`) |
| `PLATFORM_TOKEN` | Bot token (from `MATTERMOST_BOT_TOKEN`) |
| `PLATFORM_CHANNEL_ID` | Channel for permission posts |
| `PLATFORM_THREAD_ID` | Thread for permission posts |
| `PLATFORM_BOT_ID` | Bot user ID (from `MATTERMOST_BOT_ID`) |
| `ALLOWED_USERS` | Comma-separated allowed usernames |
| `PERMISSION_TIMEOUT_MS` | Permission approval timeout in ms (default: `120000`). Set in EARL's parent environment to override; inherited by the MCP subprocess. |
| `EARL_CURRENT_USERNAME` | Username of the message sender |

## Example .envrc

```bash
export MATTERMOST_URL="https://mattermost.example.com"
export MATTERMOST_BOT_TOKEN="your-bot-token-here"
export MATTERMOST_BOT_ID="your-bot-user-id"
export EARL_CHANNEL_ID="default-channel-id"
export EARL_ALLOWED_USERS="alice,bob"
export EARL_CHANNELS="chan1:~/Code/project-a,chan2:~/Code/project-b"
# export EARL_SKIP_PERMISSIONS=true  # Uncomment to skip permission prompts
```
