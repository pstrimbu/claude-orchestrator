# Claude Orchestrator

Electron-based GUI for running Claude Code sessions with integrated time tracking, issue management, and git integration.

## Quick Start

```bash
orch                      # launch for current directory
orch /path/to/project     # launch for specific project
orch --continue           # resume previous session
orch --dev                # run from working tree (not tagged release)
```

## Commands

| Command | Purpose |
|---------|---------|
| `orch` | Launch the orchestrator (Electron app) |
| `orch-launcher` | Launch the project launcher sidebar (native Swift) |
| `orch-tracker` | Unified issue tracker CLI (routes to Linear or Jira) |
| `orch-linear` | Linear GraphQL API client |
| `orch-jira` | Jira REST API client |

## Architecture

- `app/` — Electron app (main process + xterm.js renderer)
- `launcher-native/` — Native Swift/AppKit floating panel launcher
- `bin/` — CLI scripts (on PATH)
- `docs/` — Configuration and tracker documentation
- `templates/` — Issue templates for Linear/Jira

## App Structure (`app/`)

- `src/main/main.ts` — Electron main process, IPC handlers, spawns Claude PTY
- `src/main/claude-session.ts` — node-pty wrapper for Claude CLI
- `src/main/services/` — Clockify, tracker, command history
- `src/main/overlays/` — Menu panels (project, time, issues, git, history)
- `src/renderer/` — xterm.js terminal, status bar, overlay rendering
- `src/shared/ipc.ts` — IPC channel constants and types

## Hotkeys

- **F1** — Main menu (Project, Time, Issues, Git, History)
- **F5** — Restart session with `--continue`
- **Ctrl+R** — Restart Claude session in-place
- **Shift+Enter** — Send newline (multiline input)

## State

Per-project in `.orch/` (gitignored):
- `orch.pid` — Process ID for focus/cascade signals
- `project.json` — Tracker config (type, team key, title prefix)
- `scrollback.buf` — Terminal buffer persisted across restarts
- `history.json` — Command history for Clockify summaries

## Configuration

Set credentials in `.env` (project-level or repo-level):
- `CLOCKIFY_API_KEY` — Time tracking
- `LINEAR_API_KEY` — Linear issue tracker
- `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` — Jira

## Releases

`bin/orch` defaults to the latest git tag. Tagged releases are cached in `.releases/`.
Use `--dev` to run from the working tree. Use `--version=vX.Y.Z` for a specific tag.
