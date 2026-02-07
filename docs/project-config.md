# Project Configuration

Each project can have a `.orch/project.json` file that configures orchestrator behavior.

## Location

```
<project-root>/.orch/project.json
```

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `project_id` | string | yes | Stable identifier for the project |
| `linear.enabled` | boolean | yes | Enable/disable Linear integration |
| `linear.team_key` | string | if linear enabled | Linear team key (e.g., "ENG") |
| `linear.project_name` | string | no | Human-readable project name |
| `linear.workflow.*` | string | no | Custom workflow state name mappings |
| `linear.labels.*` | string | no | Default labels applied to all issues |
| `linear.title_prefix` | string | no | Prefix for issue titles (default: "[AI]") |
| `git.branch_format` | string | no | Branch naming pattern |
| `git.commit_footer_format` | string | no | Commit message footer pattern |

## Example

See [docs/examples/project.json](examples/project.json).

## Behavior

- **File missing**: Orchestrator works normally without Linear
- **`linear.enabled: false`**: Linear commands are blocked; Claude is told not to create issues
- **`linear.enabled: true`**: Claude follows Linear workflow rules from `.claude/skills/linear.md`
- **`LINEAR_API_KEY` missing**: Claude reports the missing key and continues without Linear
