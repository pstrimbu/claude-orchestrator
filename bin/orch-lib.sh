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
