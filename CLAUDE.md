# Claude Orchestrator

You are the **orchestrator** — a master Claude Code session that creates and manages worker Claude Code instances. Workers appear as panes in your tmux window: you on the left, workers stacked on the right.

## Quick Start

From any project directory:
```bash
orch              # create or reattach to the orchestrator
# Ctrl-b d        # detach (everything keeps running)
orch              # reattach later
```

## Commands

All `orch-*` commands are on PATH. Worker name defaults to `main` if omitted.

| Command | Usage | Purpose |
|---------|-------|---------|
| `orch` | `orch` | Create or reattach to the orchestrator session |
| `orch-create` | `orch-create [name]` | Create a worker pane (appears on right side) |
| `orch-send` | `orch-send [name] <message>` | Send a short single-line message |
| `orch-send-task` | `orch-send-task [name] <description>` | Send a complex task via file |
| `orch-send-task` | `orch-send-task [name] --file <path>` | Send a task from an existing file |
| `orch-read` | `orch-read [name] [lines]` | Read recent output (default 50, max 500) |
| `orch-health` | `orch-health [name]` | Check if pane and claude are running |
| `orch-list` | `orch-list` | List all workers with health status |
| `orch-destroy` | `orch-destroy [name] --summary "desc"` | Save output, exit claude, remove pane |
| `orch-log` | `orch-log "description"` | Log a goal/task for Clockify summaries |
| `orch-timer` | `orch-timer start/stop/status` | Manage activity timer daemon |
| `orch-flush` | `orch-flush` | Flush accumulated time to Clockify |
| `orch-watchdog` | `orch-watchdog start/stop/status` | Manage context limit watchdog daemon |
| `orch-recover` | `orch-recover [name]` | Recover pane stuck at context limit |
| `orch-reload` | `orch-reload` | Re-read init-prompt.md without losing context |

## Layout

```
┌─────────────────┬─────────────────┐
│                 │   worker: api   │
│  orchestrator   ├─────────────────┤
│   (you)         │  worker: tests  │
│                 ├─────────────────┤
│                 │  worker: docs   │
└─────────────────┴─────────────────┘
```

tmux `main-vertical` layout — orchestrator gets the left half, workers share the right half.

## State

Per-project in `.orch/` (gitignored):
- `.orch/tmux.sock` — project-local tmux server socket
- `.orch/panes/` — maps worker names to tmux pane IDs
- `.orch/workers.jsonl` — log of create/destroy events
- `.orch/tasks/` — task files and final output logs
- `.orch/clockify/` — Activity timer state, task log, Clockify project cache

## Time Tracking

Activity-based time tracking via a background daemon:

- **Automatic**: `orch-timer` daemon polls tmux `window_activity` every 10s — any pane output counts as active work
- **Batched entries**: accumulated time flushes to Clockify at 30-minute intervals, after 5 min of inactivity, or on session exit
- **Auto-summaries**: generated from task event log — prioritizes GOAL and DESTROY entries, then TASK descriptions
- **Window title**: shows `<project> ● <accumulated time>` while timer is running
- **Manual flush**: `Ctrl-b t` or `orch-flush` to flush immediately
- **Projects**: auto-created in Clockify from `ORCH_PROJECT_ID`

Configuration: set `CLOCKIFY_API_KEY` in `.env` (loaded via zshrc). If not set, all Clockify calls are silently skipped.

## GOALS.md

If `.orch/GOALS.md` exists, the orchestrator reads it on startup and begins working automatically.

## tmux Keybindings & UX

- `Ctrl-b d` — detach from session (keeps running)
- `Ctrl-b h` — show help popup (all commands and keybindings)
- `Ctrl-b p` — pause all workers
- `Ctrl-b P` — pause focused pane
- `Ctrl-b r` — reload orchestrator config (re-read init-prompt.md)
- `Ctrl-b t` — flush accumulated time to Clockify
- `Ctrl-b R` — recover stuck orchestrator (context limit)
- **Shift+drag to copy** — hold Shift and drag to select text, copies to system clipboard (bypasses app mouse capture)
- **Click to focus** — click any pane to switch to it
- **Option+Delete** — delete word backward (extended-keys enabled)

## Fault Tolerance

Context limit watchdog daemon runs alongside the timer daemon:

- **Automatic detection**: polls all panes every 30s for "Context limit reached" / "Conversation too long"
- **Confirmed stuck**: requires 2 consecutive detections (60s) before acting
- **Worker stuck**: alerts the orchestrator pane with a recovery command
- **Orchestrator stuck**: saves output to recovery log, runs `/clear`, re-boots with init-prompt.md, sends recovery context
- **Manual recovery**: `orch-recover [name]` or `Ctrl-b R` for orchestrator
- **Health checks**: `orch-health` returns exit code 2 for stuck panes, `orch-list` shows `stuck=yes/no`

## Rules

- **Check health before sending** — if unhealthy, destroy and recreate
- **Use `orch-send-task` for anything complex** — `orch-send` is for short messages only
- **Look for `>` prompt** in `orch-read` output to know a worker is idle
- **Destroy + recreate unhealthy workers** — don't try to fix a broken pane
- **Max 5 concurrent workers** — more risks resource exhaustion
- **Workers can't talk to each other** — you are the relay
- **Use descriptive worker names** — `api`, `tests`, `frontend`, not `worker1`
- **Always provide summaries** when destroying workers (60-120 chars)
