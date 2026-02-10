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
| `orch-list` | `orch-list` | List all workers with health and timer status |
| `orch-destroy` | `orch-destroy [name] --summary "desc"` | Save output, stop timer, exit claude, remove pane |
| `orch-clock` | `orch-clock start/stop "desc"` | Track orchestrator active time |
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
- `.orch/clockify/` — Clockify timer state (entry IDs, project cache)

## Time Tracking

Clockify integration tracks time automatically:

- **Workers**: timer starts on `orch-create`, stops on `orch-destroy`
- **Orchestrator**: use `orch-clock start "description"` / `orch-clock stop` for active work periods
- **Projects**: auto-created in Clockify from `ORCH_PROJECT_ID` (the tmux title bar name)
- **Summaries**: `orch-destroy` requires `--summary "60-120 char description"` (use `--force` to skip)

Configuration: set `CLOCKIFY_API_KEY` in `.env` (loaded via zshrc). If not set, all Clockify calls are silently skipped.

## GOALS.md

If `.orch/GOALS.md` exists, the orchestrator reads it on startup and begins working automatically.

## tmux Keybindings & UX

- `Ctrl-b d` — detach from session (keeps running)
- `Ctrl-b h` — show help popup (all commands and keybindings)
- `Ctrl-b p` — pause all workers
- `Ctrl-b P` — pause focused pane
- `Ctrl-b r` — reload orchestrator config (re-read init-prompt.md)
- **Mouse select to copy** — drag to highlight text, copies to system clipboard on release (via `pbcopy`)
- **Click to focus** — click any pane to switch to it

## Rules

- **Check health before sending** — if unhealthy, destroy and recreate
- **Use `orch-send-task` for anything complex** — `orch-send` is for short messages only
- **Look for `>` prompt** in `orch-read` output to know a worker is idle
- **Destroy + recreate unhealthy workers** — don't try to fix a broken pane
- **Max 5 concurrent workers** — more risks resource exhaustion
- **Workers can't talk to each other** — you are the relay
- **Use descriptive worker names** — `api`, `tests`, `frontend`, not `worker1`
- **Always provide summaries** when destroying workers (60-120 chars)
