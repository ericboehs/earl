# Sessions

Each Mattermost thread maps to one Claude CLI session. EARL manages the full lifecycle of these sessions, including creation, persistence, resume, and cleanup.

## Session Lifecycle

```
New message in thread (no existing session)
  -> SessionManager checks session store for resumable session
     -> If found: resume with --resume <session-id>
     -> If not found: create new session with --session-id <uuid>
  -> Claude CLI process spawned
  -> Session registered in memory (thread_id -> ClaudeSession)
  -> Session metadata saved to disk

Subsequent messages in same thread
  -> Reuse existing ClaudeSession (same process, same context window)

Session shutdown (!stop, !kill, or EARL exit)
  -> Session state persisted to disk
  -> Claude process terminated
  -> Session removed from registry
```

## Claude CLI Arguments

Every session is spawned with:

```
claude --input-format stream-json \
       --output-format stream-json \
       --verbose \
       --session-id <uuid>              # New session
       # or --resume <session-id>       # Resumed session
       --permission-prompt-tool mcp__earl__permission_prompt \
       --mcp-config /tmp/earl-mcp-<session-id>.json \
       --append-system-prompt "<memory context>"
```

Environment variables `TMUX` and `TMUX_PANE` are cleared to prevent Claude CLI from detecting a tmux session.

## Session Persistence

Sessions are persisted to `~/.config/earl/sessions.json` so they can be resumed after EARL restarts.

### JSON Schema

```json
{
  "<thread_id>": {
    "claude_session_id": "uuid",
    "channel_id": "mattermost-channel-id",
    "working_dir": "/path/to/working/dir",
    "started_at": "2025-01-15T10:00:00-06:00",
    "last_activity_at": "2025-01-15T10:30:00-06:00",
    "is_paused": false,
    "message_count": 5,
    "total_cost": 0.0456,
    "total_input_tokens": 12000,
    "total_output_tokens": 3234
  }
}
```

### Persistence Events

| Event | Action |
|-------|--------|
| New session created | Save to store |
| Session resumed | Update store entry |
| Message completed (`result` event) | Update stats (cost, tokens) |
| Activity on thread | Touch `last_activity_at` |
| `!stop` / `!kill` | Remove from store |
| EARL shutdown (SIGINT) | `pause_all` — save all sessions with `is_paused: true` |

### Atomic Writes

The session store uses atomic writes (write to temp file, then rename) to prevent corruption from concurrent access.

## Resume Flow

On EARL startup, `SessionManager#resume_all` iterates persisted sessions:

1. Skip sessions marked as `is_paused` (these await user-initiated resume)
2. For each active session, spawn a new Claude process with `--resume <session-id>`
3. If resume fails (e.g., session expired), fall back to creating a new session

After a graceful shutdown (SIGINT), all sessions are marked as paused. On restart, these sessions are not automatically resumed — they are resumed lazily when a user sends the next message in the thread (via `get_or_create`).

When a user sends a message in a thread with a persisted session:

1. `SessionManager#get_or_create` checks for a live session first
2. If no live session, checks the session store for a matching `claude_session_id`
3. Attempts resume with `--resume`; falls back to new session on failure

## Multi-Channel Routing

EARL listens on multiple channels configured via `EARL_CHANNELS`. Each channel maps to a working directory:

```bash
EARL_CHANNELS="chan1:/home/user/project-a,chan2:/home/user/project-b"
```

When a session is created, the working directory is determined by:

1. `!cd` override for the thread (if set)
2. Channel's configured working directory
3. Current working directory (fallback)

## Shutdown and Cleanup

### Graceful Shutdown (SIGINT)

1. Runner calls `SessionManager#pause_all`
2. Each session is persisted to the store with `is_paused: true`
3. Each Claude process receives INT, waits ~2s, then TERM if still alive
4. Sessions are cleared from the in-memory registry

### Session Stop (!stop)

1. Claude process is killed (INT -> TERM escalation)
2. Session removed from the in-memory registry
3. Session removed from the disk store

### Force Kill (!kill)

1. Claude process receives SIGKILL (immediate, non-catchable)
2. Session removed from both registry and store
