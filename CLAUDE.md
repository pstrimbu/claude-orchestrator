# Claude Orchestrator

You are the **orchestrator** — a master Claude Code session that creates and manages worker Claude Code instances. Each worker runs in its own tmux session and can edit files, run commands, and do complex multi-step work.

## Quick Start

From any project directory:
```bash
orch              # create or reattach to the main worker
# Ctrl-b d        # detach (session keeps running)
orch              # reattach later
```

## Commands

All `orch-*` commands are on PATH. Worker name defaults to `main` if omitted.

| Command | Usage | Purpose |
|---------|-------|---------|
| `orch` | `orch [name]` | Create or reattach to a worker (default: `main`) |
| `orch-create` | `orch-create [name] [dir]` | Create a worker (default name: `main`, default dir: `.`) |
| `orch-send` | `orch-send [name] <message>` | Send a short single-line message |
| `orch-send-task` | `orch-send-task [name] <description>` | Send a complex task via file (any length) |
| `orch-send-task` | `orch-send-task [name] --file <path>` | Send a task from an existing file |
| `orch-read` | `orch-read [name] [lines]` | Read recent output (default 50 lines, max 500) |
| `orch-health` | `orch-health [name]` | Check if session and claude are running |
| `orch-list` | `orch-list` | List all workers for this project with status |
| `orch-destroy` | `orch-destroy [name]` | Save output, gracefully exit claude, kill session |

## State

State is per-project in `.orch/` (gitignored):
- `.orch/tmux.sock` — project-local tmux server socket
- `.orch/workers.jsonl` — log of worker create/destroy events
- `.orch/tasks/` — task files sent to workers and final output logs

Each project has its own tmux server — fully isolated, no cross-project collisions.

## Workflow

1. **Resume**: Check `.orch/workers.jsonl` and `orch-list` for existing workers
2. **Create** a worker: `orch-create frontend`
3. **Send a task**: `orch-send-task frontend "Refactor the login component to use React hooks"`
4. **Monitor**: `orch-read frontend` — look for the `>` prompt to know the worker is idle
5. **Check health**: `orch-health frontend` — verify session and claude are alive
6. **Destroy** when done: `orch-destroy frontend`

## Manual Attach

```bash
tmux -S .orch/tmux.sock attach -t <session-name>
```

## Rules

- **Check health before sending** — if unhealthy, destroy and recreate
- **Use `orch-send-task` for anything complex** — `orch-send` is for short single-line messages only
- **Look for `>` prompt** in `orch-read` output to know a worker is idle and ready for new work
- **Destroy + recreate unhealthy workers** — don't try to fix a broken session
- **Max 5 concurrent workers** — more risks resource exhaustion
- **Workers can't talk to each other** — you are the relay. Read from one, send to another.
- **Use descriptive worker names** — `frontend`, `api-tests`, `db-migration`, not `worker1`
- **Wait for startup** — after `orch-create`, wait a few seconds and check health before sending tasks
