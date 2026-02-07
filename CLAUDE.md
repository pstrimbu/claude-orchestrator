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
| `orch-destroy` | `orch-destroy [name]` | Save output, exit claude, remove pane |

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

## GOALS.md

If `.orch/GOALS.md` exists, the orchestrator reads it on startup and begins working automatically.

## Rules

- **Check health before sending** — if unhealthy, destroy and recreate
- **Use `orch-send-task` for anything complex** — `orch-send` is for short messages only
- **Look for `>` prompt** in `orch-read` output to know a worker is idle
- **Destroy + recreate unhealthy workers** — don't try to fix a broken pane
- **Max 5 concurrent workers** — more risks resource exhaustion
- **Workers can't talk to each other** — you are the relay
- **Use descriptive worker names** — `api`, `tests`, `frontend`, not `worker1`
