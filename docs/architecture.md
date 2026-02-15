# Architecture

## System Diagram

```
┌─────────────┐  WebSocket   ┌──────────────┐  stdin (JSON)   ┌─────────────────┐
│ Mattermost  │ <──────────> │              │ ──────────────> │ claude CLI       │
│ (Server)    │  REST API    │  EARL Server  │                │ (stream-json)    │
│             │              │  (Laptop)    │  stdout (JSON)  │                 │
│ #earl-vtk   │              │              │ <────────────── │ session: vtk    │
│ #earl-home  │              │              │                │ session: home   │
│ DMs -> earl │              │              │                │ session: default│
└─────────────┘              └──────────────┘                └─────────────────┘
```

Each Mattermost thread maps to an independent Claude CLI process. EARL manages the lifecycle of these processes, routing messages between chat and Claude's stream-json I/O.

## File Tree

```
bin/
  earl                          # Entry point
  earl-permission-server        # MCP permission server (spawned as subprocess by Claude CLI)
  claude-context                # Context window usage helper (spawned by !context command)
  claude-usage                  # Claude Pro usage helper (spawned by !usage command)

lib/
  earl.rb                       # Module root, requires, shared logger
  earl/
    config.rb                   # ENV-based configuration
    logging.rb                  # Shared logging mixin
    formatting.rb               # Shared number formatting helpers
    permission_config.rb        # Shared permission env builder
    tool_input_formatter.rb     # Shared tool display formatting (icons, detail extraction)
    mattermost.rb               # WebSocket connection + REST API client
    mattermost/api_client.rb    # HTTP client with retry logic
    claude_session.rb           # Single Claude CLI process wrapper (stream-json I/O)
    session_manager.rb          # Maps thread IDs -> Claude sessions (thread-safe registry)
    session_store.rb            # Persists session metadata to JSON on disk
    streaming_response.rb       # Mattermost post lifecycle (create/update/debounce)
    message_queue.rb            # Per-thread message queuing for busy sessions
    command_parser.rb           # Parses !commands from message text
    command_executor.rb         # Executes !help, !stats, !stop, !kill, etc.
    question_handler.rb         # AskUserQuestion tool -> emoji reaction flow
    runner.rb                   # Main event loop, wires everything together
    cron_parser.rb              # Minimal 5-field cron expression parser
    heartbeat_config.rb         # Loads heartbeat definitions from YAML
    heartbeat_scheduler.rb      # Runs heartbeat tasks on cron/interval/one-shot schedules
    mcp/
      config.rb                 # MCP server ENV-based config (reads from parent process env)
      server.rb                 # JSON-RPC 2.0 MCP server over stdio
      approval_handler.rb       # Permission approval via Mattermost reactions
      memory_handler.rb         # save_memory / search_memory MCP tools
      heartbeat_handler.rb      # manage_heartbeat MCP tool (CRUD heartbeat schedules)
    memory/
      store.rb                  # File I/O for persistent memory (markdown files)
      prompt_builder.rb         # Builds system prompt from memory store
```

## Message Flow

```
User posts in Mattermost channel
  -> Mattermost WebSocket delivers 'posted' event
  -> Runner checks user against allowlist
  -> CommandParser checks for !commands
     -> If command: CommandExecutor handles it directly
     -> If message: MessageQueue serializes per-thread
  -> SessionManager gets/creates ClaudeSession for this thread
     -> Checks session store for resumable session
     -> Builds MCP config for permission approval
     -> Injects memory context via --append-system-prompt
  -> session.send_message(text) writes JSON to Claude stdin
  -> Claude stdout emits stream-json events
     -> "assistant" event with text -> StreamingResponse creates/updates Mattermost post
     -> "assistant" event with tool_use -> StreamingResponse shows tool icon + detail
     -> tool_use(AskUserQuestion) -> QuestionHandler posts options, waits for reaction
     -> "result" event -> final PUT with stats, process next queued message
  -> User sees threaded reply in Mattermost
```

## Key Design Patterns

**Thread-per-session**: Each Mattermost thread maps to one Claude CLI process. The `SessionManager` maintains this registry with mutex-based thread safety.

**Stream-json I/O**: Claude CLI is spawned with `--input-format stream-json --output-format stream-json --verbose`. Input is written as JSON lines to stdin; output events are read line-by-line from stdout.

**Debounced streaming**: The first text chunk creates a new Mattermost post (POST). Subsequent chunks update it (PUT) with 300ms debounce to avoid API rate limits.

**Message queuing**: When a session is busy processing, additional messages are queued per-thread and dispatched sequentially on completion.

**MCP sidecar**: Each Claude session has its own MCP server process for permission approval. The server is configured via environment variables and communicates with Mattermost independently.

**Graceful shutdown**: SIGINT triggers `pause_all` to persist session state, then sends INT to each Claude process (escalating to TERM after ~2s).
