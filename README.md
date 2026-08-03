# Claude Orchestrator

A native macOS app for running many Claude Code sessions across many projects without
losing track of which is which.

Born from a specific failure mode: a row of identical terminal windows, each running an
agent on a different project, and me typing instructions into the wrong one — then
telling an AI "oops, ignore that." The context that matters (which project is this,
what is it doing, what did I ask for last) shouldn't live only in your head.

## What it does

Each project gets its own window wrapping a real Claude Code session (SwiftTerm +
forkpty), with a header that keeps the session's identity and state in view:

- **Project name and model** — always visible, so the "wrong window" mistake can't happen
- **Token usage** toward the context limit, before compaction kicks in
- **Git and issue-tracker status** — current branch, commits waiting to push, and
  Linear/Jira integration for reading and creating issues in place
- **Recent commands** issued in the session, so "what was I doing here" has an answer
  at a glance
- **Automatic time tracking** — pushes time entries to Clockify every 30 minutes with a
  summary of the work performed, per project
- **Remote session toggle** — hand the session to Claude remote and keep working from
  your phone
- Context menus on each header item to adjust that category's settings

Sessions persist: scrollback survives restarts (F5 relaunches with `--continue`), and a
completion cue (window-title flash) signals when a session is waiting on you — so
several projects stay in flight and you only pay attention where a decision is needed.

## Quick start

```bash
git clone https://github.com/pstrimbu/claude-orchestrator.git
cd claude-orchestrator
./bin/orch ~/path/to/your/project     # builds on first run, then launches
```

Requirements: macOS, Swift toolchain (Xcode CLT), and the
[Claude Code CLI](https://claude.com/claude-code) installed and authenticated.

Optional integrations via `.env` (project-level or repo-level):

```
CLOCKIFY_API_KEY=...                          # time tracking
LINEAR_API_KEY=...                            # Linear issues
JIRA_BASE_URL=... JIRA_EMAIL=... JIRA_API_TOKEN=...   # Jira issues
```

## Commands

| Command | Purpose |
|---|---|
| `orch` | Launch for the current directory |
| `orch --continue` | Resume the previous session |
| `orch-launcher` | Floating project-launcher panel |
| `orch-tracker` | Issue tracker CLI (routes to Linear or Jira) |

Hotkeys: **F1** project panel · **F5** save scrollback + relaunch with `--continue` ·
**Ctrl+R** restart session in place.

## Layout

- `app-native/` — the current app (Swift/AppKit + SwiftTerm)
- `launcher-native/` — floating launcher panel
- `bin/` — CLI entry points
- `app/` — legacy Electron version (pre-v0.5.5, kept for history)

## Status

This is a personal tool, published as-is because people asked how I run parallel
Claude Code sessions. It's shaped to exactly how I work; expect rough edges and
opinionated defaults. Anthropic's Claude Code desktop app now covers some of this
ground natively — this exists for the parts it doesn't, and for the workflow glue
(time tracking, issue trackers, per-project state) that a general tool shouldn't have.

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free to use, modify, and share
for any **noncommercial** purpose. **Commercial use** (selling it, hosting it as a
paid service, or bundling it into a paid product) requires a separate commercial
license. For commercial licensing, contact Peter Strimbu <peter@strimbu.com>.
