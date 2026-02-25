---
title: Home
layout: home
nav_order: 1
---

# EARL Documentation

**EARL** (Engineering Assistant Relay for LLMs) is a Ruby CLI bot that connects to Mattermost via WebSocket, listens for messages in configured channels, spawns Claude Code CLI sessions, and streams responses back as threaded replies.

## Quick Start

```bash
gem install earl-bot

# Set required environment variables (see Configuration)
export MATTERMOST_URL="https://mattermost.example.com"
export MATTERMOST_BOT_TOKEN="your-bot-token"
export MATTERMOST_BOT_ID="your-bot-user-id"
export EARL_CHANNEL_ID="default-channel-id"
export EARL_ALLOWED_USERS="alice,bob"

# Start EARL
earl
```

## Reference

| Document | Description |
|----------|-------------|
| [Architecture](architecture) | System diagram, file tree, message flow, and design patterns |
| [Commands](commands) | All `!commands` with usage and examples |
| [Configuration](configuration) | Environment variables, config files, and YAML schemas |
| [Permissions](permissions) | MCP permission server, approval flow, and emoji mapping |
| [Memory](memory) | Persistent memory system, MCP tools, and file formats |
| [Heartbeats](heartbeats) | Scheduled tasks with cron, interval, and one-shot schedules |
| [Sessions](sessions) | Session lifecycle, persistence, resume, and idle timeout |
| [Streaming](streaming) | Response streaming, debouncing, tool display, and AskUserQuestion |

## Development

```bash
bin/ci                  # Run full CI pipeline
rubocop                 # Ruby style checking
rubocop -A              # Auto-fix style violations
bundle exec rake test   # Run test suite
```
