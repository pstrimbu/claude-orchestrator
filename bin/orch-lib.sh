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
# tmux session names cannot contain dots or colons
ORCH_PROJECT_ID="${_orch_project//[.:]/-}"

SESSION_PREFIX="orch-${ORCH_PROJECT_ID}-"

# Per-project tmux socket — keeps sessions isolated and in the project dir
ORCH_TMUX_SOCK="$(pwd -P)/${ORCH_STATE_DIR:-.orch}/tmux.sock"

# All tmux calls go through this wrapper
orch_tmux() {
    tmux -S "$ORCH_TMUX_SOCK" "$@"
}

orch_session_name() {
    echo "${SESSION_PREFIX}${1}"
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
}

orch_session_exists() {
    local session
    session="$(orch_session_name "$1")"
    orch_tmux has-session -t "$session" 2>/dev/null
}

orch_claude_running() {
    local session pane_pid
    session="$(orch_session_name "$1")"
    pane_pid="$(orch_tmux display-message -t "$session" -p '#{pane_pid}' 2>/dev/null)" || return 1
    pgrep -P "$pane_pid" -f claude >/dev/null 2>&1
}

orch_die() {
    echo "error: $1" >&2
    exit 1
}

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
