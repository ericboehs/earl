# EARL - Engineering Assistant Relay for LLMs

## Context

Ruby rewrite of [claude-threads](https://github.com/anneschuth/claude-threads), a TypeScript/Bun project that bridges Claude Code sessions with Mattermost/Slack. EARL is a personal AI assistant accessible via chat, running on Eric's laptop.

Long-term goal: evolve EARL toward [OpenClaw](https://github.com/openclaw/openclaw)-style capabilities — persistent memory, scheduled tasks, multi-channel, and autonomous agent features — while keeping it a simple Ruby CLI.

**Borrowing from claude-threads:**
- Thread-per-session model (each chat thread = independent Claude session)
- Emoji reactions for tool approvals (👍 approve, ✅ allow all, 👎 deny)
- `--input-format stream-json --output-format stream-json` for Claude CLI integration
- Session persistence via `--session-id` / `--resume`
- Live response streaming to chat
- MCP permission server for approval flow

**EARL differences:**
- Ruby instead of TypeScript
- Personal use (simpler auth: allowlist instead of invite system)
- `#earl-*` channel convention for multi-session management
- No git worktree features (can add later)

## Architecture

```
┌─────────────┐  WebSocket   ┌──────────────┐  stdin (JSON)   ┌─────────────────┐
│ Mattermost  │ ◄──────────► │              │ ──────────────► │ claude CLI       │
│ (NAS)       │  REST API    │  EARL Server  │                │ (stream-json)    │
│             │              │  (Laptop)    │  stdout (JSON)  │                 │
│ #earl-vtk   │              │              │ ◄────────────── │ session: vtk    │
│ #earl-home  │              │              │                │ session: home   │
│ DMs → earl  │              │              │                │ session: default│
└─────────────┘              └──────────────┘                └─────────────────┘
                                  ▲
┌─────────────┐  Socket Mode      │
│    Slack    │ ◄────────────────►│
└─────────────┘
```

## Current State

Phase 1 is complete. Phases 2–6 are implemented in PR #5. EARL connects to Mattermost via WebSocket, spawns Claude CLI sessions per thread, streams responses back with debounced POST/PUT, manages session lifecycles, supports MCP-based permission approval, commands, session persistence, persistent memory, and heartbeat scheduling.

**Built:**
- `lib/earl/claude_session.rb` — Claude CLI wrapper (stream-json I/O)
- `lib/earl/mattermost.rb` — WebSocket + REST (posted events, create/update posts, typing)
- `lib/earl/session_manager.rb` — Thread ID → Claude process registry
- `lib/earl/streaming_response.rb` — Buffered/debounced response streaming
- `lib/earl/message_queue.rb` — Per-thread message queuing
- `lib/earl/runner.rb` — Main loop wiring everything together
- `lib/earl/config.rb` — ENV-based configuration
- `lib/earl/logging.rb` — Shared logger

---

## Phases

### Phase 1: Core CLI + Mattermost MVP ✅

- Claude CLI wrapper with stream-json I/O
- Mattermost WebSocket connection + REST API
- Single-channel message routing
- Allowlist-based auth
- Streaming responses with debounce
- Per-thread session management

### Phase 2: Permission System (claude-threads parity) ✅

Replace `--dangerously-skip-permissions` with an MCP-based approval flow so Eric gets notified in Mattermost when Claude wants to use a tool.

**How it works (from claude-threads):**
1. EARL spawns a Ruby MCP server as a sidecar process for each Claude session
2. Claude CLI is started with `--permission-prompt-tool mcp__earl-permissions__permission_prompt` instead of `--dangerously-skip-permissions`
3. When Claude needs permission, it calls the MCP tool with `{ tool_name, input }`
4. The MCP server posts to the Mattermost thread: "Claude wants to run: `rm -rf /tmp/foo`" with 👍 ✅ 👎 reactions
5. MCP server polls for `reaction_added` WebSocket events from an allowed user
6. Returns `{ behavior: "allow" }` or `{ behavior: "deny" }` to Claude
7. ✅ sets "allow all" for the rest of the session

**New files:**
- `lib/earl/mcp/server.rb` — Ruby MCP stdio server exposing `permission_prompt` tool
- `lib/earl/mcp/approval_handler.rb` — Posts approval messages, listens for reactions, returns decisions

**Changes:**
- `claude_session.rb` — Remove `--dangerously-skip-permissions`, add `--mcp-config` and `--permission-prompt-tool` args
- `mattermost.rb` — Add `reaction_added` event handling, `add_reaction` REST method

**MCP server env vars (passed per-session):**
```
PLATFORM_URL, PLATFORM_TOKEN, PLATFORM_CHANNEL_ID,
PLATFORM_THREAD_ID, ALLOWED_USERS, PERMISSION_TIMEOUT_MS
```

**Emoji mapping:**
| Emoji | Action |
|-------|--------|
| 👍 `+1` | Allow this tool use |
| ✅ `white_check_mark` | Allow all for this session |
| 👎 `-1` | Deny this tool use |

### Phase 3: AskUserQuestion + Commands ✅

Handle Claude's `AskUserQuestion` tool and add chat commands for session control.

**AskUserQuestion flow:**
1. Detect `tool_use` content block with `name: "AskUserQuestion"` in assistant events
2. Post questions to Mattermost with numbered emoji reactions (1️⃣ 2️⃣ 3️⃣ 4️⃣)
3. Collect reaction from allowed user
4. Send answer back to Claude stdin as a regular user message (not tool_result — per claude-threads findings)

**Chat commands** (messages starting with `!`):**
| Command | Description |
|---------|-------------|
| `!stop` | End current session |
| `!escape` | Interrupt Claude mid-response (SIGINT) |
| `!kill` | Emergency kill Claude process |
| `!cd <path>` | Change session working directory |
| `!help` | Show available commands |
| `!cost` | Show token costs for session |
| `!compact` | Compact conversation history |
| `!permissions auto\|interactive` | Toggle auto-approve vs emoji approvals |

### Phase 4: Session Persistence + Multi-Channel ✅

**Session persistence:**
- Store session mapping in `~/.config/earl/sessions.json` (thread_id → session_id, working_dir, created_at)
- On EARL restart, resume existing sessions with `--resume <session-id>`
- Idle timeout: after N seconds of inactivity, pause session and post notice

**Multi-channel:**
- Listen on multiple `#earl-*` channels (not just one `EARL_CHANNEL_ID`)
- Channel → working directory mapping (e.g., `#earl-vtk` → `~/Code/.../vtk`)
- DMs to EARL bot → default session

---

## OpenClaw-Inspired Phases

These phases take EARL beyond claude-threads parity toward OpenClaw-style autonomous agent capabilities.

### Phase 5: Persistent Memory ✅

Give EARL long-term memory that survives across sessions and restarts, so it remembers past conversations and user preferences.

**Approach (from OpenClaw):**
- `~/.config/earl/memory/` directory with date-stamped markdown files (`YYYY-MM-DD.md`)
- `MEMORY.md` for curated long-term facts (user preferences, project context)
- Claude can write to memory via a `save_memory` MCP tool
- Claude can search memory via a `search_memory` MCP tool (keyword matching, or later semantic search)
- On session start, inject relevant memory as system prompt context

**New files:**
- `lib/earl/memory_store.rb` — Read/write/search markdown memory files
- Memory MCP tools added to the existing permission MCP server (or a second MCP server)

**Bootstrap files (OpenClaw pattern):**
- `SOUL.md` — EARL's personality, tone, boundaries (injected as system prompt via `--system-prompt` or prepended to first message)
- `USER.md` — Eric's preferences, identity, communication style

### Phase 6: Heartbeats + Scheduled Tasks ✅

Let EARL proactively perform tasks on a schedule without waiting for a message.

- `~/.config/earl/heartbeats.yml` — YAML-based heartbeat configuration (cron or interval schedule)
- `CronParser` — Minimal 5-field cron parser (supports *, values, ranges, steps, lists)
- `HeartbeatConfig` — Loads and validates heartbeat definitions from YAML
- `HeartbeatScheduler` — Core scheduler with per-heartbeat threads, overlap protection, timeout handling
- Header post in channel with Claude response as threaded reply
- `!heartbeats` command to show status table
- Persistent sessions (reuse Claude session across runs) or fresh sessions per run
- Permission mode support (auto or interactive per heartbeat)

### Phase 7: Multi-Platform (Slack, Discord, etc.)

Abstract the chat platform behind an adapter interface so EARL can run on multiple platforms with unified state.

**Approach (from OpenClaw's Gateway pattern):**
- Extract `Platform` interface: `connect`, `on_message`, `create_post`, `update_post`, `add_reaction`, `wait_for_reaction`
- `lib/earl/platforms/mattermost.rb` — Current code, refactored to interface
- `lib/earl/platforms/slack.rb` — Slack Socket Mode + Web API
- Unified session state across platforms (same memory, same user identity)
- Channel routing config in `~/.config/earl/config.yml`

### Phase 8: Skill System

Let EARL learn new capabilities by writing its own skill files — small, focused tool definitions that persist across sessions.

**Approach (from OpenClaw):**
- `~/.config/earl/skills/` directory with Ruby or markdown skill files
- Skills are MCP tools or prompt snippets that get loaded into Claude's context
- Claude can create new skills via a `create_skill` tool
- Skills are versioned (git-backed) and can be shared

**Examples:**
- `skills/deploy.rb` — "When I say deploy, run these specific commands"
- `skills/standup.rb` — "Summarize my git commits and PR activity since yesterday"
- `skills/home-assistant.rb` — "Check sensor readings via HA API"

### Phase 9: Multi-Agent Routing

Run multiple Claude personalities with distinct capabilities, routing messages to the right agent.

**Approach (from OpenClaw):**
- `~/.config/earl/agents/` directory with per-agent config (SOUL.md, tools, working dir)
- Prefix-based routing: `@research <query>` → research agent, `@code <task>` → coding agent
- Separate session namespaces per agent
- Shared memory for inter-agent collaboration
- Default agent handles unrouted messages

### Phase 10: Context Compaction + Token Management

Smart context window management for long-running sessions.

**Approach:**
- Monitor token usage via Claude CLI `result` events (`total_cost_usd`, context window info)
- Auto-compact when approaching context limits (Claude CLI handles this, but EARL should surface it)
- `!compact` command for manual compaction
- Post context usage stats on request (`!context`)

---

## Build Order Summary

| Phase | Name | Key Deliverable | Depends On |
|-------|------|-----------------|------------|
| 1 ✅ | Core MVP | DM EARL → get response | — |
| 2 ✅ | Permissions | Emoji-based tool approval in Mattermost | Phase 1 |
| 3 ✅ | Questions + Commands | AskUserQuestion + `!` commands | Phase 2 |
| 4 ✅ | Persistence + Multi-Channel | Session resume, `#earl-*` channels | Phase 1 |
| 5 ✅ | Memory | Long-term memory across sessions | Phase 2 |
| 6 ✅ | Heartbeats | Scheduled autonomous tasks | Phase 5 |
| 7 | Multi-Platform | Slack/Discord adapters | Phase 4 |
| 8 | Skills | Self-authoring tool plugins | Phase 5 |
| 9 | Multi-Agent | Agent routing + personalities | Phase 5, 7 |
| 10 | Token Management | Context compaction + usage stats | Phase 4 |

## Verification Milestones

1. ✅ `ruby bin/earl` → connects to Mattermost, responds to messages
2. Claude tries `Bash` → approval post with emojis → approve → command runs
3. Claude asks a question → numbered emojis → select answer → Claude continues
4. Restart EARL → sessions resume where they left off
5. "Remember that I prefer dark mode" → saved to memory → recalled next session
6. ✅ Heartbeats: EARL posts scheduled tasks to configured channel on cron/interval
7. Post in Slack → EARL responds, same memory as Mattermost
8. "Create a skill for checking CI" → skill file created → usable next session
9. `@research what is OpenClaw` → routes to research agent with web tools
