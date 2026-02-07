# Linear Integration

The orchestrator can track work in Linear, creating parent issues and subtasks for each orchestrator run.

## Setup

### 1. Set API key

```bash
export LINEAR_API_KEY="lin_api_..."
```

Store in AWS Secrets Manager: `linear/claude-code-api-key`

### 2. Create project config

```bash
mkdir -p .orch
cat > .orch/project.json << 'EOF'
{
  "project_id": "my-project",
  "linear": {
    "enabled": true,
    "team_key": "ENG",
    "project_name": "MY-PROJECT",
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

The orchestrator will read the config and follow Linear workflow rules.

## Disabling Linear

Set `linear.enabled` to `false`:

```json
{
  "project_id": "my-project",
  "linear": {
    "enabled": false,
    "team_key": "ENG"
  }
}
```

Or remove `.orch/project.json` entirely — Linear is disabled by default.

## CLI: orch-linear

### Create parent issue
```bash
orch-linear parent create --run-id "20260206-153000" --title "Add user auth" --body-file body.md
```

### Create subtask
```bash
orch-linear subtask create --parent-id <ISSUE_ID> --title "Backend JWT" --body-file body.md --run-id "20260206-153000"
```

### Update status
```bash
orch-linear issue status --key ENG-42 --set "In Progress"
orch-linear issue status --key ENG-42 --set "Done"
```

### Add labels
```bash
orch-linear issue label --key ENG-42 --add "bug,urgent"
```

### Add comment
```bash
orch-linear issue comment --key ENG-42 --file comment.md
```

### Show issue
```bash
orch-linear issue show --key ENG-42
```

### Verify auth
```bash
orch-linear viewer
```

## State Tracking

All Linear operations are logged to `.orch/state/linear.jsonl` with:
- `run_id`, `issue_id`, `issue_key`, `type`, `timestamp`

## Typical Flow

1. Orchestrator starts, reads GOALS.md
2. Creates parent Linear issue for the goal
3. Breaks goal into subtasks → creates Linear subtasks
4. Assigns subtasks to workers
5. Workers update status as they progress
6. Workers add completion comments with commits/PRs
7. Orchestrator verifies and marks parent Done
