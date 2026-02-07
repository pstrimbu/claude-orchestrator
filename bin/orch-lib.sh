#!/usr/bin/env bash
# orch-lib.sh — Shared library for claude-orchestrator scripts
# Source this file, do not execute it directly.

ORCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    [[ -n "$pane_id" ]] && orch_tmux display-message -t "$pane_id" -p '' 2>/dev/null
}

orch_claude_running() {
    local pane_id pane_pid
    pane_id="$(orch_worker_pane "$1")" || return 1
    pane_pid="$(orch_tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)" || return 1
    pgrep -P "$pane_pid" -f claude >/dev/null 2>&1
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

orch_linear_state_dir() {
    local dir="${ORCH_STATE_DIR:-.orch}/state"
    mkdir -p "$dir"
    echo "$dir"
}

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

orch_linear_enabled() {
    [[ "$(orch_project_config_get 'linear.enabled')" == "true" ]]
}

orch_linear_team_key() {
    orch_project_config_get "linear.team_key"
}

orch_linear_title_prefix() {
    local prefix
    prefix="$(orch_project_config_get 'linear.title_prefix')"
    echo "${prefix:-[AI]}"
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

    if orch_linear_enabled; then
        local skill_path="$ORCH_HOME/.claude/skills/linear.md"
        if [[ -f "$skill_path" ]]; then
            msg="$msg Read $skill_path and follow its Linear workflow rules."
        fi
    elif orch_project_config_exists; then
        msg="$msg Linear is disabled for this project. Do not create or update Linear issues."
    fi

    if [[ "$role" == "orchestrator" ]]; then
        local goals_file="$workdir/GOALS.md"
        if [[ -f "$goals_file" ]]; then
            msg="$msg Then read the project goals at $goals_file and begin working on them."
        fi
    fi

    echo "$msg"
}
