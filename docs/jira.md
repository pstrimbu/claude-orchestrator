# Jira Integration

The orchestrator can track work in Jira, creating parent issues and subtasks for each orchestrator run.

## Setup

### 1. Set API credentials

```bash
export JIRA_BASE_URL="https://mycompany.atlassian.net"
export JIRA_EMAIL="you@company.com"
export JIRA_API_TOKEN="your-api-token"
```

Get an API token from: https://id.atlassian.com/manage-profile/security/api-tokens

### 2. Create project config

```bash
mkdir -p .orch
cat > .orch/project.json << 'EOF'
{
  "project_id": "my-project",
  "tracker": { "type": "jira" },
  "jira": {
    "project_key": "ENG",
    "issue_type": "Task",
    "subtask_type": "Sub-task",
    "title_prefix": "[AI]"
  }
}
EOF
```

### 3. Start orchestrator

```bash
cd ~/dev/my-project
orch
```

The orchestrator will read the config and follow Jira workflow rules.

## Disabling Jira

Set `tracker.type` to `"none"`:

```json
{
  "project_id": "my-project",
  "tracker": { "type": "none" }
}
```

Or remove `.orch/project.json` entirely — no tracker is configured by default.

## CLI: orch-tracker (routes to orch-jira)

### Create parent issue
```bash
orch-tracker parent create --run-id "20260206-153000" --title "Add user auth" --body-file body.md
```

### Create subtask
```bash
orch-tracker subtask create --parent-key ENG-42 --title "Backend JWT" --body-file body.md --run-id "20260206-153000"
```

### Update status
```bash
orch-tracker issue status --key ENG-42 --set "In Progress"
orch-tracker issue status --key ENG-42 --set "Done"
```

Note: Jira uses workflow transitions — only valid transitions from the current state will work.

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

## State Tracking

All Jira operations are logged to `.orch/state/jira.jsonl` with:
- `run_id`, `issue_id`, `issue_key`, `type`, `timestamp`

## Typical Flow

1. Orchestrator starts, reads GOALS.md
2. Creates parent Jira issue for the goal
3. Breaks goal into subtasks → creates Jira subtasks
4. Assigns subtasks to workers
5. Workers update status as they progress
6. Workers add completion comments with commits/PRs
7. Orchestrator verifies and marks parent Done

## Differences from Linear

| Feature | Linear | Jira |
|---|---|---|
| Parent reference | `--parent-id <UUID>` | `--parent-key ENG-42` |
| Status changes | Direct state assignment | Workflow transitions |
| Labels | Objects with IDs | Plain strings |
| Subtask type | Same as parent | Separate "Sub-task" type |
| API auth | Single API key | Email + API token |
| Description format | Markdown | Atlassian Document Format (auto-converted) |
