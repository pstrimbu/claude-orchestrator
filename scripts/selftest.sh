#!/usr/bin/env bash
# selftest.sh — Verify orchestrator and linear integration basics
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

pass=0
fail=0

check() {
    local desc="$1"
    shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

check_false() {
    local desc="$1"
    shift
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (expected failure)"
        fail=$((fail + 1))
    fi
}

check_output() {
    local desc="$1"
    local expected="$2"
    shift 2
    local output
    output="$("$@" 2>/dev/null)" || true
    if [[ "$output" == *"$expected"* ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$output')"
        fail=$((fail + 1))
    fi
}

echo "=== Syntax checks ==="
for f in "$ORCH_HOME/bin/orch"*; do
    [[ "$(basename "$f")" == "orch-linear" ]] && continue  # python
    check "$(basename "$f") syntax" bash -n "$f"
done
check "orch-linear syntax" python3 -c "import py_compile; py_compile.compile('$ORCH_HOME/bin/orch-linear', doraise=True)"

echo ""
echo "=== Config helpers (no project.json) ==="
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check_false "orch_project_config_exists returns false" orch_project_config_exists
check_false "orch_linear_enabled returns false" orch_linear_enabled
check_output "orch_linear_title_prefix defaults to [AI]" "[AI]" orch_linear_title_prefix

echo ""
echo "=== Config helpers (linear disabled) ==="
mkdir -p "$TEMP_DIR/.orch"
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "linear": {"enabled": false, "team_key": "TST"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_project_config_exists returns true" orch_project_config_exists
check_false "orch_linear_enabled returns false" orch_linear_enabled
check_output "orch_linear_team_key returns TST" "TST" orch_linear_team_key

echo ""
echo "=== Config helpers (linear enabled) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "linear": {"enabled": true, "team_key": "ENG", "title_prefix": "[TEST]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_linear_enabled returns true" orch_linear_enabled
check_output "orch_linear_title_prefix returns [TEST]" "[TEST]" orch_linear_title_prefix

echo ""
echo "=== Boot message builder ==="
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
msg="$(orch_build_boot_msg orchestrator)"
check_output "boot msg includes init-prompt" "init-prompt.md" echo "$msg"
check_output "boot msg includes linear skill" "linear.md" echo "$msg"
check_output "boot msg includes session warning" "never destroy" echo "$msg"

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "linear": {"enabled": false}}
EOF
source "$ORCH_HOME/bin/orch-lib.sh"
msg="$(orch_build_boot_msg worker)"
check_output "disabled: boot msg says Linear disabled" "disabled" echo "$msg"
check_false "disabled: boot msg omits linear.md" grep -q 'linear.md' <<< "$msg"

echo ""
echo "=== orch-linear CLI ==="
check "orch-linear --help" "$ORCH_HOME/bin/orch-linear" --help

# If LINEAR_API_KEY is set, test auth
if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    echo ""
    echo "=== Linear API auth (live) ==="
    check "orch-linear viewer" "$ORCH_HOME/bin/orch-linear" viewer
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
