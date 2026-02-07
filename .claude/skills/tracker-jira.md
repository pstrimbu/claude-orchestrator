# Jira-Specific Tracker Rules

These rules apply when `tracker.type` is `"jira"` in `.orch/project.json`.

## Prerequisites

- `JIRA_BASE_URL` — your Jira instance URL (configurable via `jira.auth.base_url_env`)
- `JIRA_EMAIL` — your Jira account email (configurable via `jira.auth.email_env`)
- `JIRA_API_TOKEN` — API token (configurable via `jira.auth.api_token_env`)
- If any are missing: announce "Jira credentials not set — skipping Jira operations" and continue
- Run `orch-tracker doctor` to validate setup

## Config (.orch/project.json)

```json
{
  "project_id": "my-project",
  "tracker": { "type": "jira" },
  "jira": {
    "project_key": "ENG",
    "issue_type": "Task",
    "subtask_issue_type": "Sub-task",
    "title_prefix": "[AI]",
    "labels": ["ai-generated"],
    "status": {
      "todo": "To Do",
      "in_progress": "In Progress",
      "done": "Done"
    }
  }
}
```

## CLI Reference

### Create parent issue
```bash
orch-tracker parent create --run-id "20260206-153000" --title "Add user auth" --body-file body.md
```

### Create subtask
```bash
orch-tracker subtask create --parent-key ENG-42 --title "Backend JWT" --body-file body.md --run-id "20260206-153000"
```

Note: Jira uses `--parent-key` (e.g., ENG-42) instead of Linear's `--parent-id`.

### Update status (semantic names supported)
```bash
orch-tracker issue status --key ENG-42 --set "in_progress"   # maps to configured name
orch-tracker issue status --key ENG-42 --set "done"           # maps to configured name
orch-tracker issue status --key ENG-42 --set "In Progress"    # literal name also works
```

Semantic status names (`todo`, `in_progress`, `done`, `blocked`) are mapped to real Jira status names via `jira.status.*` config.

### Add labels
```bash
orch-tracker issue label --key ENG-42 --add "bug,urgent"
```

### Add comment
```bash
orch-tracker issue comment --key ENG-42 --file comment.md
```

### Show issue
```bash
orch-tracker issue show --key ENG-42
```

### Verify auth
```bash
orch-tracker viewer
```

### Preflight check
```bash
orch-tracker doctor
```

## State Tracking

All Jira operations are logged to:
- `.orch/state/jira.jsonl` — Jira-specific log
- `.orch/state/tracker.jsonl` — Tracker-agnostic index

## Jira-Specific Notes

- Jira uses workflow transitions — you can only move to states reachable from the current state
- Subtasks use "Sub-task" issue type by default (configurable via `jira.subtask_issue_type`)
- Some orgs use "Story" or custom types instead of "Task" — configure via `jira.issue_type`
- Labels in Jira are plain strings — they're created automatically if they don't exist
- Issue descriptions use Atlassian Document Format (ADF) — the CLI handles conversion
- Auth env var names can be overridden per-project via `jira.auth.*` (for multi-project setups)
