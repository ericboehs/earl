---
title: Streaming
nav_order: 9
---

# Streaming

EARL streams Claude's responses to Mattermost in real time, creating and updating posts as text and tool-use events arrive.

## Response Lifecycle

```
Claude emits first text chunk
  -> StreamingResponse creates a new Mattermost post (POST)
  -> Stops typing indicator

Claude emits subsequent text chunks
  -> Appended to accumulated text
  -> Debounced PUT update (300ms)

Claude emits tool_use event
  -> Tool icon + name + detail appended to post
  -> Debounced PUT update

Claude emits result event
  -> Final PUT with complete text + stats footer
  -> Any pending debounce timer is flushed
```

## Debounce Logic

To avoid hitting Mattermost API rate limits, updates are debounced:

- **First chunk**: Creates the post immediately (POST)
- **Subsequent chunks**: If 300ms have elapsed since the last update, update immediately. Otherwise, schedule an update after the remaining debounce time
- **Completion**: Flush any pending debounce timer, then do a final update

The debounce timer runs in a separate thread per response.

## Multi-Segment Responses

When Claude's response includes both text and tool use, the response is split into segments. On completion:

- **Text-only responses**: The existing post is updated with the final text and stats footer
- **Mixed responses** (text + tool use): The final text answer is extracted into a new separate post (with stats footer), and the tool-use segments remain in the original post. This keeps the final answer clearly visible.

## Tool Use Display

When Claude uses a tool, it's displayed inline with an icon and relevant details:

| Tool | Icon | Detail Shown |
|------|------|--------------|
| Bash | 🔧 | `command` |
| Read | 📖 | `file_path` |
| Edit | ✏️ | `file_path` |
| Write | 📝 | `file_path` |
| WebFetch | 🌐 | `url` |
| WebSearch | 🌐 | `query` |
| Glob | 🔍 | `pattern` |
| Grep | 🔍 | `pattern` |
| Task | 👥 | JSON input |
| AskUserQuestion | ❓ | (handled separately) |
| Other tools | ⚙️ | JSON input |

### Tool Display Format

```
🔧 `Bash`
\```
ls -la /tmp
\```
```

Tools without meaningful detail show just the icon and name:

```
⚙️ `ToolName`
```

`AskUserQuestion` tool use events are excluded from the streaming post display (they're handled by `QuestionHandler` instead).

## Stats Footer

On completion, a stats summary line is appended after a horizontal rule:

```
---
42,000 tokens · 21% context
```

## AskUserQuestion Flow

When Claude uses the `AskUserQuestion` tool, EARL posts the question with numbered emoji reactions instead of streaming it inline.

### Flow

1. Claude emits a `tool_use` event with `name: "AskUserQuestion"`
2. `QuestionHandler` posts the question to the thread with options:

```
❓ **Which database should we use?**
:one: PostgreSQL — Battle-tested relational database
:two: SQLite — Lightweight, no server needed
:three: MongoDB — Document store for flexible schemas
```

3. EARL adds numbered emoji reactions (1️⃣ 2️⃣ 3️⃣ 4️⃣) to the post
4. User reacts with a number emoji to select their answer
5. The question post is deleted
6. The answer is sent back to Claude as a user message (not a `tool_result`)
7. If there are multiple questions, the next one is posted

### Emoji Mapping

| Emoji | Index |
|-------|-------|
| `one` (1️⃣) | 0 (first option) |
| `two` (2️⃣) | 1 (second option) |
| `three` (3️⃣) | 2 (third option) |
| `four` (4️⃣) | 3 (fourth option) |

## Typing Indicator

While waiting for Claude's first response, EARL sends typing indicators to Mattermost every 3 seconds. The typing indicator stops as soon as the first text chunk arrives or a tool use is displayed.
