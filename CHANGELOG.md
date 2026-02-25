# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-02-24

Initial public release. EARL has been in active personal use since June 2025,
running ~96 commits of development before this first tagged release.

### Added

- **Core bot** — WebSocket connection to Mattermost, message routing, and Claude CLI spawning
- **Streaming responses** — first text chunk creates a post, subsequent chunks update via debounced PUT
- **Session persistence** — follow-up messages in same thread reuse the same Claude context; sessions survive restarts
- **Permission approval** — tool use gated by Mattermost emoji reactions via MCP sidecar server
- **Persistent memory** — markdown-based memory files (SOUL.md, USER.md, daily notes) injected into Claude sessions
- **Memory MCP tools** — `save_memory` and `search_memory` for Claude to manage its own memory
- **Heartbeat scheduler** — cron, interval, and one-shot (`run_at`) scheduled tasks that spawn Claude sessions
- **Heartbeat MCP tool** — `manage_heartbeat` for Claude to CRUD heartbeat schedules at runtime
- **Tmux session supervisor** — Mattermost as control plane for all running Claude sessions (EARL-managed and standalone)
- **Tmux MCP tool** — `manage_tmux_sessions` for Claude to list, capture, approve, spawn, and kill tmux sessions
- **GitHub PAT MCP tool** — Safari automation for creating fine-grained GitHub personal access tokens
- **Commands** — `!help`, `!stats`, `!stop`, `!kill`, `!compact`, `!cd`, `!permissions`, `!heartbeats`, `!usage`, `!context`, `!sessions`, `!session`, `!restart`, `!spawn`, `!update`, `!escape`
- **Dev/prod environments** — simultaneous dev and prod instances with separate config, bots, and channels
- **Claude HOME isolation** — EARL's Claude sessions use an isolated config directory
- **Thread context** — new sessions in existing threads get Mattermost transcript for context
- **Message queuing** — per-thread message queue for busy sessions
- **Graceful shutdown** — SIGINT/SIGTERM pauses sessions; SIGHUP restarts in-place
- **Install script** — `earl-install` sets up config dirs, clones prod repo, creates wrapper

### Changed

- Converted from Rails application to standalone Ruby gem (`earl-bot`)
- Replaced Rails test infrastructure with plain Minitest
- Simplified Gemfile from 92 lines (Rails + ~30 gems) to gemspec + 1 runtime dependency

[0.1.0]: https://github.com/ericboehs/earl/releases/tag/v0.1.0
