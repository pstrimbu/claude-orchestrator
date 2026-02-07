# Tracker Workflow Rules (Agnostic)

You MUST follow these rules when a tracker is configured for this project (.orch/project.json `tracker.type` is set to "linear" or "jira").

## Prerequisites

- Check which tracker is configured: `tracker.type` in .orch/project.json
- Ensure the required API credentials are set (see tracker-specific skill for details)
- If credentials are missing: announce and continue without tracker operations
- Always use `orch-tracker` CLI — never make raw API calls

## Workflow

### 1. Create parent issue

At the start of each goal/run, create ONE parent issue:

```bash
orch-tracker parent create --run-id "$(date +%Y%m%d-%H%M%S)" --title "Description of goal" --body-file /path/to/body.md
```

### 2. Create subtasks

Break the parent into subtasks (max ~10; group if more). The exact CLI flags depend on the tracker type — see tracker-specific skill.

### 3. Status transitions

```bash
orch-tracker issue status --key <KEY> --set "In Progress"   # when starting work
orch-tracker issue status --key <KEY> --set "Done"           # after verified
```

### 4. Completion

Mark "Done" ONLY after verification passes. Add a final comment:

```bash
echo "## Completion Summary
- Commits: <list>
- PR: <link if any>
- Verification: <what was tested and passed>
" > /tmp/comment.md
orch-tracker issue comment --key <KEY> --file /tmp/comment.md
orch-tracker issue status --key <KEY> --set "Done"
```

### 5. Labels

Default labels from .orch/project.json are applied automatically. Add extra:

```bash
orch-tracker issue label --key <KEY> --add "bug,urgent"
```

## Rules

- ONE parent issue per orchestrator run/goal
- Subtasks map to worker tasks where possible
- Never mark Done without verification
- All tracker state is logged to `.orch/state/` automatically
- If tracker is not configured or disabled, do NOT perform any tracker operations
- If `orch-tracker` fails, report the error and continue — do not retry in a loop
