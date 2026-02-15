# Permissions

EARL uses an MCP-based permission system to control which tools Claude can use. When Claude needs to run a tool (e.g., Bash, Edit, Write), the user is prompted in Mattermost to approve or deny.

## How It Works

EARL spawns a Ruby MCP server (`bin/earl-permission-server`) as a sidecar process for each Claude session. Claude CLI is configured to call this server whenever it needs tool permission.

### Approval Flow

```
Claude wants to use a tool (e.g., Bash)
  -> Claude calls mcp__earl__permission_prompt with { tool_name, input }
  -> MCP server posts permission request to Mattermost thread
  -> MCP server adds reaction options (👍 ✅ 👎)
  -> MCP server opens a WebSocket and waits for a reaction from an allowed user
  -> User reacts with an emoji
  -> MCP server returns { behavior: "allow" } or { behavior: "deny" } to Claude
  -> Permission request post is deleted from the thread
```

### Claude CLI Arguments

With permissions enabled (default):
```
claude --permission-prompt-tool mcp__earl__permission_prompt \
       --mcp-config /tmp/earl-mcp-<session-id>.json \
       --input-format stream-json --output-format stream-json --verbose
```

With permissions skipped (`EARL_SKIP_PERMISSIONS=true`):
```
claude --dangerously-skip-permissions \
       --input-format stream-json --output-format stream-json --verbose
```

## Emoji Mapping

| Emoji | Name | Action |
|-------|------|--------|
| 👍 | `+1` | Allow this tool use (one-time) |
| ✅ | `white_check_mark` | Always allow this tool for the rest of the session |
| 👎 | `-1` | Deny this tool use |

## Permission Request Format

Permission requests appear in the Mattermost thread as:

```
🔒 **Permission Request**
Claude wants to run: `Bash`
\```
ls -la /tmp
\```
React: 👍 allow once | ✅ always allow `Bash` | 👎 deny
```

The displayed input varies by tool:
- **Bash**: Shows the `command` field (truncated to 500 chars)
- **Edit/Write**: Shows `file_path` and a preview of content (truncated to 300 chars)
- **Other tools**: Shows JSON-serialized input (truncated to 500 chars)

## Per-Thread Tool Allowlists

When a user reacts with ✅ (always allow), the tool name is added to a per-thread allowlist stored at:

```
~/.config/earl/allowed_tools/<thread_id>.json
```

This is a JSON array of tool name strings (e.g., `["Bash", "Read", "Write"]`). Future uses of these tools in the same thread are auto-approved without prompting.

## Timeout

If no reaction is received within the timeout period (default: 120 seconds, configurable via `PERMISSION_TIMEOUT_MS`), the tool use is denied automatically.

## Skip Permissions Mode

Set `EARL_SKIP_PERMISSIONS=true` to bypass the permission system entirely. Claude is spawned with `--dangerously-skip-permissions`, allowing all tool use without approval. Use this for trusted environments only.
