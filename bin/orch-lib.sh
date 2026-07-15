#!/usr/bin/env bash
# orch-lib.sh — Shared library for claude-orchestrator scripts
# Source this file, do not execute it directly.

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source .env and export credentials so child processes (timer daemon, flush) inherit them
if [[ -f "$ORCH_HOME/.env" ]]; then
    set -a
    source "$ORCH_HOME/.env"
    set +a
fi

# Project ID: derived from cwd basename, sanitized for tmux (no dots/colons).
# Override with ORCH_PROJECT env var.
if [[ -n "${ORCH_PROJECT:-}" ]]; then
    _orch_project="$ORCH_PROJECT"
else
    _orch_project="$(basename "$PWD")"
fi
ORCH_PROJECT_ID="${_orch_project//[.:]/-}"

# Single tmux session per project, named after project
ORCH_SESSION="orch-${ORCH_PROJECT_ID}"

# Per-project tmux socket
ORCH_TMUX_SOCK="$(pwd -P)/${ORCH_STATE_DIR:-.orch}/tmux.sock"

# All tmux calls go through this wrapper
orch_tmux() {
    tmux -S "$ORCH_TMUX_SOCK" "$@"
}

ORCH_DEFAULT_WORKER="main"

orch_resolve_name() {
    echo "${1:-$ORCH_DEFAULT_WORKER}"
}

orch_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        orch_die "name is required"
    fi
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        orch_die "invalid name '$name': must match [a-zA-Z0-9_-]+"
    fi
    if [[ "$name" == "orchestrator" ]]; then
        orch_die "reserved name 'orchestrator' — choose a different worker name"
    fi
}

orch_die() {
    echo "error: $1" >&2
    exit 1
}

# --- Pane-based worker management ---

orch_pane_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}/panes"
    mkdir -p "$dir"
    echo "$dir"
}

orch_worker_pane() {
    local pane_file
    pane_file="$(orch_pane_dir)/$1"
    [[ -f "$pane_file" ]] && cat "$pane_file"
}

orch_worker_exists() {
    local pane_id
    pane_id="$(orch_worker_pane "$1")" || return 1
    [[ -n "$pane_id" ]] && orch_tmux display-message -t "$pane_id" -p '' >/dev/null 2>&1
}

orch_claude_running() {
    local pane_id pane_pid
    pane_id="$(orch_worker_pane "$1")" || return 1
    pane_pid="$(orch_tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)" || return 1
    pgrep -P "$pane_pid" -f claude >/dev/null 2>&1
}

# Check if a pane is stuck at context limit.
# Takes a tmux pane ID (not worker name). Returns 0 if stuck.
orch_pane_stuck() {
    local pane_id="$1"
    local output
    output="$(orch_tmux capture-pane -t "$pane_id" -p -S -15 -J 2>/dev/null)" || return 1
    echo "$output" | grep -qiE 'context limit reached|Conversation too long|conversation is too long'
}

orch_session_exists() {
    orch_tmux has-session -t "$ORCH_SESSION" 2>/dev/null
}

orch_relayout() {
    orch_tmux select-layout -t "$ORCH_SESSION" main-vertical 2>/dev/null || true
}

# --- State directories ---

orch_task_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}/tasks"
    mkdir -p "$dir"
    echo "$dir"
}

orch_state_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}"
    mkdir -p "$dir"
    echo "$dir"
}

orch_tracker_state_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}/state"
    mkdir -p "$dir"
    echo "$dir"
}

# Backward compat alias
orch_linear_state_dir() { orch_tracker_state_dir; }

# --- Project config (.orch/project.json) ---

orch_project_config_path() {
    echo "${ORCH_STATE_DIR:-.orch}/project.json"
}

orch_project_config_exists() {
    [[ -f "$(orch_project_config_path)" ]]
}

# Read a dotted key from project.json using python. Returns empty string if missing.
# Usage: orch_project_config_get "linear.enabled"
orch_project_config_get() {
    local key="$1"
    local config_path
    config_path="$(orch_project_config_path)"
    [[ -f "$config_path" ]] || return 0
    python3 -c "
import json, sys
try:
    with open('$config_path') as f:
        d = json.load(f)
    keys = '$key'.split('.')
    for k in keys:
        d = d[k]
    print(d if not isinstance(d, bool) else str(d).lower())
except (KeyError, TypeError, FileNotFoundError, json.JSONDecodeError):
    pass
" 2>/dev/null
}

# --- Tracker abstraction ---
# Supports new tracker.* config and backward-compat with linear.* config.
# tracker.type = "linear" | "jira" | "none" (default: inferred from config)

orch_tracker_type() {
    local explicit
    explicit="$(orch_project_config_get 'tracker.type')"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    # Backward compat: infer from legacy linear.* config
    if [[ "$(orch_project_config_get 'linear.enabled')" == "true" ]]; then
        echo "linear"
        return
    fi
    echo "none"
}

orch_tracker_enabled() {
    local tracker_type
    tracker_type="$(orch_tracker_type)"
    [[ "$tracker_type" != "none" ]]
}

orch_tracker_team_key() {
    local tracker_type
    tracker_type="$(orch_tracker_type)"
    case "$tracker_type" in
        linear) orch_project_config_get "linear.team_key" ;;
        jira)   orch_project_config_get "jira.project_key" ;;
        *)      echo "" ;;
    esac
}

orch_tracker_title_prefix() {
    # tracker.title_prefix overrides tracker-specific prefix
    local override
    override="$(orch_project_config_get 'tracker.title_prefix')"
    if [[ -n "$override" ]]; then
        echo "$override"
        return
    fi
    local tracker_type prefix
    tracker_type="$(orch_tracker_type)"
    case "$tracker_type" in
        linear) prefix="$(orch_project_config_get 'linear.title_prefix')" ;;
        jira)   prefix="$(orch_project_config_get 'jira.title_prefix')" ;;
        *)      prefix="" ;;
    esac
    echo "${prefix:-[AI]}"
}

# Returns merged labels: tracker.labels (agnostic) + tracker-specific labels.
# Output: newline-separated label names.
orch_tracker_labels() {
    local tracker_type
    tracker_type="$(orch_tracker_type)"
    # Agnostic labels from tracker.labels (python handles both array and object)
    local agnostic_labels
    agnostic_labels="$(python3 -c "
import json, sys
try:
    with open('$(orch_project_config_path)') as f:
        d = json.load(f)
    labels = d.get('tracker', {}).get('labels', [])
    if isinstance(labels, dict):
        labels = list(labels.values())
    for l in labels:
        print(l)
except:
    pass
" 2>/dev/null)" || true
    # Tracker-specific labels
    local specific_labels
    specific_labels="$(python3 -c "
import json, sys
try:
    with open('$(orch_project_config_path)') as f:
        d = json.load(f)
    key = '$tracker_type'
    labels = d.get(key, {}).get('labels', [])
    if isinstance(labels, dict):
        labels = list(labels.values())
    for l in labels:
        print(l)
except:
    pass
" 2>/dev/null)" || true
    # Merge, dedupe
    echo -e "${agnostic_labels}\n${specific_labels}" | sort -u | grep -v '^$' || true
}

# Legacy aliases for backward compat
orch_linear_enabled() {
    [[ "$(orch_tracker_type)" == "linear" ]]
}

orch_linear_team_key() {
    orch_project_config_get "linear.team_key"
}

orch_linear_title_prefix() {
    local prefix
    prefix="$(orch_project_config_get 'linear.title_prefix')"
    echo "${prefix:-[AI]}"
}

orch_jira_enabled() {
    [[ "$(orch_tracker_type)" == "jira" ]]
}

# --- Clockify time tracking ---

CLOCKIFY_BASE_URL="https://api.clockify.me/api/v1"
# Set these in .env. Find them via `GET api.clockify.me/api/v1/user`
# (`activeWorkspace` and `id`). Empty means time tracking is not configured.
CLOCKIFY_WORKSPACE_ID="${CLOCKIFY_WORKSPACE_ID:-}"
CLOCKIFY_USER_ID="${CLOCKIFY_USER_ID:-}"

orch_clockify_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}/clockify"
    mkdir -p "$dir"
    echo "$dir"
}

# curl wrapper: method path [json_body]
orch_clockify_api() {
    local method="$1" path="$2" body="${3:-}"
    if [[ -z "${CLOCKIFY_API_KEY:-}" ]]; then
        echo "warning: CLOCKIFY_API_KEY not set — skipping clockify" >&2
        return 1
    fi
    local args=(-s -X "$method" -H "X-Api-Key: $CLOCKIFY_API_KEY" -H "Content-Type: application/json")
    if [[ -n "$body" ]]; then
        args+=(-d "$body")
    fi
    curl "${args[@]}" "${CLOCKIFY_BASE_URL}${path}" 2>/dev/null
}

# Find or create a Clockify project matching ORCH_PROJECT_ID.
# Caches project ID in .orch/clockify/.project-id
orch_clockify_find_or_create_project() {
    local clockify_dir
    clockify_dir="$(orch_clockify_dir)"
    local cache_file="$clockify_dir/.project-id"

    # Return cached ID if available
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi

    local project_name="$ORCH_PROJECT_ID"
    local ws_path="/workspaces/$CLOCKIFY_WORKSPACE_ID"

    # Search for existing project
    local response
    response="$(orch_clockify_api GET "${ws_path}/projects?name=${project_name}&page-size=50")" || return 1
    local project_id
    project_id="$(echo "$response" | python3 -c "
import json, sys
try:
    projects = json.load(sys.stdin)
    for p in projects:
        if p['name'] == '$project_name':
            print(p['id'])
            sys.exit(0)
except:
    pass
" 2>/dev/null)" || true

    if [[ -z "$project_id" ]]; then
        # Create project
        local create_body="{\"name\":\"$project_name\"}"
        response="$(orch_clockify_api POST "${ws_path}/projects" "$create_body")" || return 1
        project_id="$(echo "$response" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin)['id'])
except:
    pass
" 2>/dev/null)" || true
    fi

    if [[ -z "$project_id" ]]; then
        echo "warning: could not find or create clockify project '$project_name'" >&2
        return 1
    fi

    echo "$project_id" > "$cache_file"
    echo "$project_id"
}

# Log a task event for summary generation during flush
# Usage: orch_log_task "EVENT" "description"
orch_log_task() {
    local event="$1" description="$2"
    local log_file
    log_file="$(orch_clockify_dir)/tasks.log"
    description="$(echo "$description" | tr '|' '-' | tr '\n' ' ' | head -c 200)"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|${event}|${description}" >> "$log_file"
}

# --- Boot message builder ---
# Builds the priming message for both orchestrator and worker panes.
# Usage: orch_build_boot_msg [--role orchestrator|worker]
orch_build_boot_msg() {
    local role="${1:-worker}"
    local workdir
    workdir="$(pwd -P)"
    local msg="Read the file at $ORCH_HOME/init-prompt.md and follow its instructions."

    if [[ "$role" == "orchestrator" ]]; then
        msg="$msg You are in session $ORCH_SESSION — never destroy your own session."
    else
        msg="$msg You are a worker. Focus on the tasks assigned to you."
    fi

    local config_path
    config_path="$(orch_project_config_path)"
    if [[ -f "$config_path" ]]; then
        msg="$msg Read the project config at $workdir/$config_path and obey it."
    fi

    local tracker_type
    tracker_type="$(orch_tracker_type)"
    if [[ "$tracker_type" != "none" ]]; then
        # Load tracker-agnostic skill
        local tracker_skill="$ORCH_HOME/.claude/skills/tracker.md"
        if [[ -f "$tracker_skill" ]]; then
            msg="$msg Read $tracker_skill and follow its tracker workflow rules."
        fi
        # Load tracker-specific skill
        local specific_skill="$ORCH_HOME/.claude/skills/tracker-${tracker_type}.md"
        if [[ -f "$specific_skill" ]]; then
            msg="$msg Read $specific_skill for ${tracker_type}-specific rules."
        fi
        # Legacy: also load linear.md if it exists and tracker is linear
        if [[ "$tracker_type" == "linear" ]]; then
            local linear_skill="$ORCH_HOME/.claude/skills/linear.md"
            if [[ -f "$linear_skill" ]]; then
                msg="$msg Read $linear_skill and follow its Linear workflow rules."
            fi
        fi
    elif orch_project_config_exists; then
        msg="$msg Issue tracking is disabled for this project. Do not create or update tracker issues."
    fi

    if [[ "$role" == "orchestrator" ]]; then
        local goals_file="$workdir/${ORCH_STATE_DIR:-.orch}/GOALS.md"
        if [[ -f "$goals_file" ]]; then
            msg="$msg Then read the project goals at $goals_file and begin working on them."
        fi
    fi

    echo "$msg"
}
