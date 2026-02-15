# Memory

EARL has a persistent memory system that lets Claude remember facts across sessions and restarts. Memory is stored as markdown files and injected into Claude sessions as system prompt context.

## Directory Structure

```
~/.config/earl/memory/
  SOUL.md              # Core identity and personality
  USER.md              # User preferences and notes
  2025-01-14.md        # Daily episodic memory
  2025-01-15.md        # Daily episodic memory
  ...
```

## File Formats

### SOUL.md

EARL's personality, tone, and behavioral boundaries. Written manually. Injected as the "Core Identity" section of the system prompt.

### USER.md

Notes about users (preferences, communication style, context). Written manually or by Claude via `save_memory`. Injected as the "User Notes" section.

### YYYY-MM-DD.md (Daily Memory)

Episodic memories saved by Claude during conversations. Each entry is a timestamped line:

```markdown
# Memories for 2025-01-15

- **14:30 UTC** | `@alice` | Prefers dark mode in all editors
- **15:45 UTC** | `@bob` | Working on the authentication refactor this week
```

New entries are appended with a file lock to prevent corruption from concurrent writes.

## MCP Tools

Claude can save and search memory via MCP tools exposed by the permission server.

### save_memory

Saves a fact or observation to today's daily memory file.

**Input schema:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `text` | string | yes | The fact or observation to save |
| `username` | string | no | The username this memory relates to |

**Behavior:** Appends a timestamped entry to `~/.config/earl/memory/YYYY-MM-DD.md`. Creates the file with a date header if it doesn't exist.

### search_memory

Searches all memory files for matching text using case-insensitive keyword matching.

**Input schema:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `query` | string | yes | Keywords to search for |
| `limit` | integer | no | Maximum results to return (default: 20) |

**Behavior:** Searches files in priority order: SOUL.md, USER.md, then daily files (newest first). Returns matching lines with their source file.

**Example response:**
```
Found 2 memories:
**USER.md**: - Prefers dark mode in all editors
**2025-01-14.md**: - **14:30 UTC** | `@alice` | Prefers dark mode in all editors
```

## Memory Injection

On session start, `Memory::PromptBuilder` assembles memory into a system prompt passed via `--append-system-prompt`. The prompt is wrapped in `<earl-memory>` tags:

```
<earl-memory>
## Core Identity
[contents of SOUL.md]

## User Notes
[contents of USER.md]

## Recent Memories
[last 7 days of daily entries, up to 50 lines]
</earl-memory>

You have persistent memory via save_memory and search_memory tools.
Save important facts you learn. Search when you need to recall something.
```

Sections are omitted if their source file is empty or doesn't exist.
