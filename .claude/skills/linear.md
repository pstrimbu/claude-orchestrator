# Linear Workflow Rules

You MUST follow these rules when Linear is enabled for this project (.orch/project.json `linear.enabled: true`).

## Prerequisites

- `LINEAR_API_KEY` must be set in the environment
- If missing: announce "LINEAR_API_KEY not set — skipping Linear operations" and continue without Linear
- Never attempt raw HTTP/GraphQL calls — always use `orch-linear` CLI

## Workflow

### 1. Create parent issue

At the start of each goal/run, create ONE parent issue:

```bash
orch-linear parent create --run-id "$(date +%Y%m%d-%H%M%S)" --title "Description of goal" --body-file /path/to/body.md
```

Use templates at `~/dev/claude-orchestrator/templates/linear-parent.md` for body format.

### 2. Create subtasks

Break the parent into subtasks (max ~10; group if more):

```bash
orch-linear subtask create --parent-id <PARENT_ISSUE_ID> --title "Subtask description" --body-file /path/to/body.md --run-id <RUN_ID>
```

Use templates at `~/dev/claude-orchestrator/templates/linear-subtask.md` for body format.

### 3. Status transitions

```bash
orch-linear issue status --id <ID> --set "In Progress"   # when starting work
orch-linear issue status --id <ID> --set "Done"           # after verified
orch-linear issue status --id <ID> --set "Blocked"        # if blocked
```

Valid transitions: Queued → In Progress → Done | Blocked | Abandoned

### 4. Completion

Mark "Done" ONLY after verification passes. Add a final comment:

```bash
echo "## Completion Summary
- Commits: <list>
- PR: <link if any>
- Verification: <what was tested and passed>
" > /tmp/comment.md
orch-linear issue comment --id <ID> --file /tmp/comment.md
orch-linear issue status --id <ID> --set "Done"
```

### 5. Labels

Default labels from .orch/project.json are applied automatically. Add extra:

```bash
orch-linear issue label --id <ID> --add "bug,urgent"
```

## Rules

- ONE parent issue per orchestrator run/goal
- Subtasks map to worker tasks where possible
- Never mark Done without verification
- All Linear state is logged to `.orch/state/linear.jsonl` automatically
- If `linear.enabled` is false or missing, do NOT perform any Linear operations
- If `orch-linear` fails, report the error and continue — do not retry in a loop
