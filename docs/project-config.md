# Project Configuration

Each project can have a `.orch/project.json` file that configures orchestrator behavior.

## Location

```
<project-root>/.orch/project.json
```

## First Use

Run `orch-tracker doctor` to validate your configuration before first use.

## Configuration Matrix

| | **Linear** | **Jira** | **None** |
|---|---|---|---|
| `tracker.type` | `"linear"` | `"jira"` | `"none"` (default) |
| Required config | `linear.team_key` | `jira.project_key` | — |
| Required env vars | `LINEAR_API_KEY` | `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` | — |
| Auth indirection | `linear.auth.api_key_env` | `jira.auth.base_url_env`, `jira.auth.email_env`, `jira.auth.api_token_env` | — |
| Issue types | N/A (Linear uses labels) | `jira.issue_type`, `jira.subtask_issue_type` | — |
| Status mapping | `linear.workflow.*` | `jira.status.*` (semantic: todo, in_progress, done) | — |
| Example | `docs/examples/project.json` | `docs/examples/project-jira.json` | — |

## Tracker-Agnostic Fields

These override tracker-specific equivalents:

| Field | Type | Description |
|---|---|---|
| `tracker.type` | string | `"linear"`, `"jira"`, or `"none"` |
| `tracker.title_prefix` | string | Overrides `linear.title_prefix` / `jira.title_prefix` |
| `tracker.labels` | array/object | Merged with tracker-specific labels |

## All Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `project_id` | string | yes | Stable identifier for the project |
| `tracker.type` | string | no | Tracker type: "linear", "jira", or "none" |
| `tracker.title_prefix` | string | no | Agnostic title prefix override |
| `tracker.labels` | array/object | no | Agnostic labels (merged with tracker-specific) |
| **Linear** | | | |
| `linear.enabled` | boolean | no | Legacy toggle (prefer tracker.type) |
| `linear.team_key` | string | if linear | Linear team key (e.g., "ENG") |
| `linear.project_name` | string | no | Auto-created if missing |
| `linear.workflow.*` | string | no | Workflow state name mappings |
| `linear.labels.*` | string | no | Default labels for issues |
| `linear.title_prefix` | string | no | Title prefix (default: "[AI]") |
| `linear.auth.api_key_env` | string | no | Env var name for API key (default: "LINEAR_API_KEY") |
| **Jira** | | | |
| `jira.project_key` | string | if jira | Jira project key (e.g., "ENG") |
| `jira.issue_type` | string | no | Parent issue type (default: "Task") |
| `jira.subtask_issue_type` | string | no | Subtask issue type (default: "Sub-task") |
| `jira.title_prefix` | string | no | Title prefix (default: "[AI]") |
| `jira.labels` | array/object | no | Default labels for issues |
| `jira.status.todo` | string | no | Semantic "todo" status name (default: "To Do") |
| `jira.status.in_progress` | string | no | Semantic "in_progress" name (default: "In Progress") |
| `jira.status.done` | string | no | Semantic "done" name (default: "Done") |
| `jira.status.blocked` | string | no | Semantic "blocked" name (default: "Blocked") |
| `jira.auth.base_url_env` | string | no | Env var name for base URL (default: "JIRA_BASE_URL") |
| `jira.auth.email_env` | string | no | Env var name for email (default: "JIRA_EMAIL") |
| `jira.auth.api_token_env` | string | no | Env var name for API token (default: "JIRA_API_TOKEN") |
| **Git** | | | |
| `git.branch_format` | string | no | Branch naming pattern |
| `git.commit_footer_format` | string | no | Commit message footer pattern |

## Auth Env Var Indirection

By default the CLIs read from standard env var names. For multi-project setups, override via config:

```json
{
  "jira": {
    "auth": {
      "base_url_env": "MYPROJ_JIRA_URL",
      "email_env": "MYPROJ_JIRA_EMAIL",
      "api_token_env": "MYPROJ_JIRA_TOKEN"
    }
  }
}
```

The config stores **env var names**, never secrets.

## Examples

See [docs/examples/](examples/) for complete examples.

## Setup Checklists

### Linear

1. Get API key from Linear settings > API
2. `export LINEAR_API_KEY="lin_api_..."`
3. Create `.orch/project.json` with `tracker.type: "linear"` and `linear.team_key`
4. Run `orch-tracker doctor`

### Jira Cloud

1. Get API token from https://id.atlassian.com/manage-profile/security/api-tokens
2. Set env vars: `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN`
3. Create `.orch/project.json` with `tracker.type: "jira"` and `jira.project_key`
4. Run `orch-tracker doctor`

## Behavior

- **File missing**: Orchestrator works normally without any tracker
- **`tracker.type: "none"`** or missing: No tracker operations
- **`tracker.type: "linear"`**: Claude follows Linear workflow rules
- **`tracker.type: "jira"`**: Claude follows Jira workflow rules
- **Legacy `linear.enabled: true`**: Same as `tracker.type: "linear"` (backward compatible)
- **Missing API credentials**: Claude reports the missing credentials and continues without tracker
