# Claude Orchestrator

Native macOS (Swift/AppKit) app for running Claude Code sessions with integrated time tracking, issue management, and git integration. Uses SwiftTerm for terminal emulation.

## Quick Start

```bash
orch                      # launch for current directory
orch /path/to/project     # launch for specific project
orch --continue           # resume previous session
```

## Commands

| Command | Purpose |
|---------|---------|
| `orch` | Launch the orchestrator (native Swift app) |
| `orch-launcher` | Launch the project launcher sidebar (native Swift) |
| `orch-tracker` | Unified issue tracker CLI (routes to Linear or Jira) |
| `orch-linear` | Linear GraphQL API client |
| `orch-jira` | Jira REST API client |

## Architecture

- `app-native/` — Native Swift/AppKit app with SwiftTerm terminal
- `app/` — Legacy Electron app (preserved on main branch, pre-v0.5.5)
- `launcher-native/` — Native Swift/AppKit floating panel launcher
- `bin/` — CLI scripts (on PATH)
- `docs/` — Configuration and tracker documentation
- `templates/` — Issue templates for Linear/Jira

## App Structure (`app-native/`)

- `Sources/Orch/main.swift` — Entry point, CLI arg parsing
- `Sources/Orch/AppDelegate.swift` — NSWindow, SwiftTerm TerminalView, PTY I/O, hotkeys
- `Sources/Orch/ClaudeSession.swift` — forkpty wrapper for Claude CLI
- `Sources/Orch/Config.swift` — Project configuration (.orch/project.json)
- `Sources/Orch/StatusBarView.swift` — SwiftUI status bar (project, time, issues, git)
- `Sources/Orch/OverlayManager.swift` — Overlay state machine and keyboard navigation
- `Sources/Orch/OverlayView.swift` — SwiftUI overlay rendering
- `Sources/Orch/Services/` — ClockifyService, TrackerService, CommandHistory
- `Sources/Orch/Overlays/` — Project, Time, Issues, Git, History, Prompt, Setup overlays

## Hotkeys

- **F1** — Project panel
- **F5** — Save scrollback, relaunch with `--continue`
- **Ctrl+R** — Restart Claude session in-place
- **Cmd+Q** — Quit

## State

Per-project in `.orch/` (gitignored):
- `orch.pid` — Process ID for focus/cascade signals
- `project.json` — Tracker config (type, team key, title prefix)
- `scrollback.buf` — Terminal buffer persisted across restarts
- `command-history.jsonl` — Command history for Clockify summaries

## Configuration

Set credentials in `.env` (project-level or repo-level):
- `CLOCKIFY_API_KEY` — Time tracking
- `LINEAR_API_KEY` — Linear issue tracker
- `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` — Jira

## Build

```bash
cd app-native && swift build           # debug build
cd app-native && swift build -c release  # release build (2.9MB binary)
```

`bin/orch` auto-builds on first run and rebuilds when sources change.
