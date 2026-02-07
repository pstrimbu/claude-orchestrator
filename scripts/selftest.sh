#!/usr/bin/env bash
# selftest.sh — Verify orchestrator, tracker abstraction, and integration basics
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

# Python module loader helper (extensionless files need explicit SourceFileLoader)
cat > "$TEMP_DIR/_load.py" << PYEOF
from importlib.util import spec_from_file_location, module_from_spec
from importlib.machinery import SourceFileLoader
def load(path):
    spec = spec_from_file_location('mod', path, loader=SourceFileLoader('mod', path))
    mod = module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
PYEOF

echo "=== Syntax checks ==="
for f in "$ORCH_HOME/bin/orch"*; do
    base="$(basename "$f")"
    # Skip python scripts for bash syntax check
    [[ "$base" == "orch-linear" ]] && continue
    [[ "$base" == "orch-jira" ]] && continue
    check "$base syntax" bash -n "$f"
done
check "orch-linear syntax" python3 -c "import py_compile; py_compile.compile('$ORCH_HOME/bin/orch-linear', doraise=True)"
check "orch-jira syntax" python3 -c "import py_compile; py_compile.compile('$ORCH_HOME/bin/orch-jira', doraise=True)"

echo ""
echo "=== Config helpers (no project.json) ==="
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check_false "orch_project_config_exists returns false" orch_project_config_exists
check_false "orch_tracker_enabled returns false" orch_tracker_enabled
check_false "orch_linear_enabled returns false" orch_linear_enabled
check_false "orch_jira_enabled returns false" orch_jira_enabled
check_output "orch_tracker_type defaults to none" "none" orch_tracker_type
check_output "orch_linear_title_prefix defaults to [AI]" "[AI]" orch_linear_title_prefix
check_output "orch_tracker_title_prefix defaults to [AI]" "[AI]" orch_tracker_title_prefix

echo ""
echo "=== Config helpers (legacy linear.enabled=false) ==="
mkdir -p "$TEMP_DIR/.orch"
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "linear": {"enabled": false, "team_key": "TST"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_project_config_exists returns true" orch_project_config_exists
check_false "orch_tracker_enabled returns false (linear disabled)" orch_tracker_enabled
check_false "orch_linear_enabled returns false" orch_linear_enabled
check_output "orch_tracker_type returns none" "none" orch_tracker_type
check_output "orch_linear_team_key returns TST" "TST" orch_linear_team_key

echo ""
echo "=== Config helpers (legacy linear.enabled=true) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "linear": {"enabled": true, "team_key": "ENG", "title_prefix": "[TEST]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_linear_enabled returns true (legacy)" orch_linear_enabled
check "orch_tracker_enabled returns true (inferred from legacy)" orch_tracker_enabled
check_output "orch_tracker_type infers linear from legacy" "linear" orch_tracker_type
check_output "orch_linear_title_prefix returns [TEST]" "[TEST]" orch_linear_title_prefix
check_output "orch_tracker_title_prefix returns [TEST] (via linear)" "[TEST]" orch_tracker_title_prefix

echo ""
echo "=== Config helpers (tracker.type=linear) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "linear"}, "linear": {"team_key": "ENG", "title_prefix": "[LIN]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_tracker_enabled returns true" orch_tracker_enabled
check "orch_linear_enabled returns true" orch_linear_enabled
check_false "orch_jira_enabled returns false" orch_jira_enabled
check_output "orch_tracker_type returns linear" "linear" orch_tracker_type
check_output "orch_tracker_team_key returns ENG" "ENG" orch_tracker_team_key
check_output "orch_tracker_title_prefix returns [LIN]" "[LIN]" orch_tracker_title_prefix

echo ""
echo "=== Config helpers (tracker.type=jira) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira"}, "jira": {"project_key": "PROJ", "title_prefix": "[JIRA]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check "orch_tracker_enabled returns true (jira)" orch_tracker_enabled
check_false "orch_linear_enabled returns false (jira)" orch_linear_enabled
check "orch_jira_enabled returns true" orch_jira_enabled
check_output "orch_tracker_type returns jira" "jira" orch_tracker_type
check_output "orch_tracker_team_key returns PROJ" "PROJ" orch_tracker_team_key
check_output "orch_tracker_title_prefix returns [JIRA]" "[JIRA]" orch_tracker_title_prefix

echo ""
echo "=== Config helpers (tracker.type=none) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "none"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"

check_false "orch_tracker_enabled returns false (explicit none)" orch_tracker_enabled
check_false "orch_linear_enabled returns false (explicit none)" orch_linear_enabled
check_false "orch_jira_enabled returns false (explicit none)" orch_jira_enabled
check_output "orch_tracker_type returns none" "none" orch_tracker_type

echo ""
echo "=== Agnostic title_prefix override (orch-lib.sh) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "linear", "title_prefix": "[OVERRIDE]"}, "linear": {"team_key": "ENG", "title_prefix": "[LIN]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
check_output "tracker.title_prefix overrides linear.title_prefix" "[OVERRIDE]" orch_tracker_title_prefix

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira", "title_prefix": "[OVERRIDE]"}, "jira": {"project_key": "PROJ", "title_prefix": "[JIRA]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
check_output "tracker.title_prefix overrides jira.title_prefix" "[OVERRIDE]" orch_tracker_title_prefix

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira"}, "jira": {"project_key": "PROJ", "title_prefix": "[JIRA-ONLY]"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
check_output "jira.title_prefix used when tracker.title_prefix absent" "[JIRA-ONLY]" orch_tracker_title_prefix

echo ""
echo "=== Agnostic labels merge (orch-lib.sh) ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira", "labels": ["shared-1", "shared-2"]}, "jira": {"project_key": "PROJ", "labels": ["jira-specific"]}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
labels="$(orch_tracker_labels)"
check_output "merged labels include shared-1" "shared-1" echo "$labels"
check_output "merged labels include shared-2" "shared-2" echo "$labels"
check_output "merged labels include jira-specific" "jira-specific" echo "$labels"

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira", "labels": ["dup-label"]}, "jira": {"project_key": "PROJ", "labels": ["dup-label", "unique"]}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
labels="$(orch_tracker_labels)"
dup_count=$(echo "$labels" | grep -c "dup-label")
check "merged labels deduplicates" test "$dup_count" -eq 1
check_output "merged labels include unique" "unique" echo "$labels"

echo ""
echo "=== Boot message builder ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "linear"}, "linear": {"team_key": "ENG"}}
EOF
cd "$TEMP_DIR"
source "$ORCH_HOME/bin/orch-lib.sh"
msg="$(orch_build_boot_msg orchestrator)"
check_output "boot msg includes init-prompt" "init-prompt.md" echo "$msg"
check_output "boot msg includes tracker skill" "tracker.md" echo "$msg"
check_output "boot msg includes linear skill" "linear.md" echo "$msg"
check_output "boot msg includes session warning" "never destroy" echo "$msg"

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira"}, "jira": {"project_key": "ENG"}}
EOF
source "$ORCH_HOME/bin/orch-lib.sh"
msg="$(orch_build_boot_msg worker)"
check_output "jira: boot msg includes tracker skill" "tracker.md" echo "$msg"
check_output "jira: boot msg includes jira-specific skill" "tracker-jira.md" echo "$msg"
check_false "jira: boot msg omits linear.md" grep -q 'linear.md' <<< "$msg"

cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "none"}}
EOF
source "$ORCH_HOME/bin/orch-lib.sh"
msg="$(orch_build_boot_msg worker)"
check_output "disabled: boot msg says tracking disabled" "disabled" echo "$msg"
check_false "disabled: boot msg omits tracker.md" grep -q 'tracker.md' <<< "$msg"

echo ""
echo "=== orch-tracker CLI ==="
check "orch-tracker syntax" bash -n "$ORCH_HOME/bin/orch-tracker"

echo ""
echo "=== orch-linear CLI ==="
check "orch-linear --help" "$ORCH_HOME/bin/orch-linear" --help

echo ""
echo "=== orch-jira CLI ==="
check "orch-jira --help" "$ORCH_HOME/bin/orch-jira" --help

echo ""
echo "=== orch-tracker doctor ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "none"}}
EOF
cd "$TEMP_DIR"
check_output "doctor none: says no tracker configured" "No tracker configured" "$ORCH_HOME/bin/orch-tracker" doctor

# Doctor with linear but no API key (run in subshell to avoid env leakage)
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "linear"}, "linear": {"team_key": "TST"}}
EOF
check_false "doctor linear: fails without api key" bash -c "unset LINEAR_API_KEY 2>/dev/null; cd '$TEMP_DIR'; '$ORCH_HOME/bin/orch-tracker' doctor"

# Doctor with jira but no env vars
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira"}, "jira": {"project_key": "PROJ"}}
EOF
check_false "doctor jira: fails without env vars" bash -c "unset JIRA_BASE_URL JIRA_EMAIL JIRA_API_TOKEN 2>/dev/null; cd '$TEMP_DIR'; '$ORCH_HOME/bin/orch-tracker' doctor"

# Doctor with custom auth env var names (checks correct names in output)
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "jira"}, "jira": {"project_key": "PROJ", "auth": {"base_url_env": "CUSTOM_URL", "email_env": "CUSTOM_EMAIL", "api_token_env": "CUSTOM_TOKEN"}}}
EOF
cd "$TEMP_DIR"
doctor_out="$("$ORCH_HOME/bin/orch-tracker" doctor 2>/dev/null)" || true
check_output "doctor jira custom auth: checks CUSTOM_URL" "CUSTOM_URL" echo "$doctor_out"
check_output "doctor jira custom auth: checks CUSTOM_EMAIL" "CUSTOM_EMAIL" echo "$doctor_out"
check_output "doctor jira custom auth: checks CUSTOM_TOKEN" "CUSTOM_TOKEN" echo "$doctor_out"

echo ""
echo "=== orch-tracker routing ==="
cat > "$TEMP_DIR/.orch/project.json" << 'EOF'
{"project_id": "test", "tracker": {"type": "none"}}
EOF
cd "$TEMP_DIR"
check_false "tracker routes none: exits with error for non-doctor" "$ORCH_HOME/bin/orch-tracker" viewer

echo ""
echo "=== orch-linear Python function tests ==="

# check_linear_enabled: tracker.type=linear (Section A)
check "linear: check_linear_enabled accepts tracker.type=linear" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
mod.check_linear_enabled({'tracker': {'type': 'linear'}})
"

# check_linear_enabled: legacy linear.enabled=true
check "linear: check_linear_enabled accepts linear.enabled=true" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
mod.check_linear_enabled({'linear': {'enabled': True}})
"

# check_linear_enabled: neither set → dies
check_false "linear: check_linear_enabled rejects unconfigured" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
mod.check_linear_enabled({})
"

# check_linear_enabled: --force bypasses
check "linear: check_linear_enabled force bypasses" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
mod.check_linear_enabled({}, force=True)
"

# get_api_key: custom env var name (Section C)
check "linear: get_api_key reads custom env var" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
os.environ.pop('LINEAR_API_KEY', None)
os.environ['MY_LINEAR_KEY'] = 'test-key-123'
mod = load('$ORCH_HOME/bin/orch-linear')
key = mod.get_api_key({'linear': {'auth': {'api_key_env': 'MY_LINEAR_KEY'}}})
assert key == 'test-key-123', f'got {key}'
"

# get_api_key: default env var name
check "linear: get_api_key defaults to LINEAR_API_KEY" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
os.environ['LINEAR_API_KEY'] = 'default-key-456'
mod = load('$ORCH_HOME/bin/orch-linear')
key = mod.get_api_key({})
assert key == 'default-key-456', f'got {key}'
"

# get_api_key: missing env var → dies
check_false "linear: get_api_key dies when env var missing" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
os.environ.pop('LINEAR_API_KEY', None)
os.environ.pop('NONEXISTENT_KEY', None)
mod = load('$ORCH_HOME/bin/orch-linear')
mod.get_api_key({'linear': {'auth': {'api_key_env': 'NONEXISTENT_KEY'}}})
"

# resolve_title_prefix: tracker.title_prefix override (Section B)
check "linear: resolve_title_prefix uses tracker override" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
r = mod.resolve_title_prefix({'tracker': {'title_prefix': '[OVER]'}, 'linear': {'title_prefix': '[LIN]'}})
assert r == '[OVER]', f'got {r}'
"

# resolve_title_prefix: linear fallback
check "linear: resolve_title_prefix falls back to linear.title_prefix" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
r = mod.resolve_title_prefix({'linear': {'title_prefix': '[LIN]'}})
assert r == '[LIN]', f'got {r}'
"

# resolve_title_prefix: default [AI]
check "linear: resolve_title_prefix defaults to [AI]" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
r = mod.resolve_title_prefix({})
assert r == '[AI]', f'got {r}'
"

# resolve_labels: merge all sources (Section B)
check "linear: resolve_labels merges agnostic + specific + CLI" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
config = {'tracker': {'labels': ['shared']}, 'linear': {'labels': {'bug': 'bug-label'}}}
r = mod.resolve_labels(config, 'cli-label')
assert 'shared' in r, f'missing shared: {r}'
assert 'bug-label' in r, f'missing bug-label: {r}'
assert 'cli-label' in r, f'missing cli-label: {r}'
"

# resolve_labels: dedup case-insensitive
check "linear: resolve_labels deduplicates case-insensitive" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-linear')
r = mod.resolve_labels({'tracker': {'labels': ['Bug']}, 'linear': {'labels': ['bug']}})
assert len(r) == 1, f'expected 1 label, got {len(r)}: {r}'
"

# log_linear_event: dual logging (Section G)
check "linear: log_linear_event writes to both files" python3 -c "
import sys, os, json, tempfile; sys.path.insert(0, '$TEMP_DIR')
from _load import load
tmpdir = tempfile.mkdtemp()
os.environ['ORCH_STATE_DIR'] = tmpdir
mod = load('$ORCH_HOME/bin/orch-linear')
mod.log_linear_event({'type': 'test_event', 'issue_key': 'ENG-1', 'title': 'Test', 'run_id': 'r1'})
ll = [json.loads(l) for l in open(os.path.join(tmpdir, 'state', 'linear.jsonl')).readlines()]
tl = [json.loads(l) for l in open(os.path.join(tmpdir, 'state', 'tracker.jsonl')).readlines()]
assert ll[0]['type'] == 'test_event'
assert 'timestamp' in ll[0]
assert tl[0]['tracker_type'] == 'linear'
assert tl[0]['action'] == 'test_event'
assert tl[0]['issue_key'] == 'ENG-1'
"

echo ""
echo "=== orch-jira Python function tests ==="

# check_jira_enabled: tracker.type=jira (Section A equivalent)
check "jira: check_jira_enabled accepts tracker.type=jira" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
mod.check_jira_enabled({'tracker': {'type': 'jira'}})
"

# check_jira_enabled: legacy jira.enabled=true
check "jira: check_jira_enabled accepts jira.enabled=true" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
mod.check_jira_enabled({'jira': {'enabled': True}})
"

# check_jira_enabled: neither set → dies
check_false "jira: check_jira_enabled rejects unconfigured" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
mod.check_jira_enabled({})
"

# check_jira_enabled: --force bypasses
check "jira: check_jira_enabled force bypasses" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
mod.check_jira_enabled({}, force=True)
"

# get_auth: custom env var names (Section C)
check "jira: get_auth reads custom env var names" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
for v in ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']:
    os.environ.pop(v, None)
os.environ['MY_JIRA_URL'] = 'https://test.atlassian.net'
os.environ['MY_JIRA_EMAIL'] = 'test@example.com'
os.environ['MY_JIRA_TOKEN'] = 'tok123'
mod = load('$ORCH_HOME/bin/orch-jira')
config = {'jira': {'auth': {'base_url_env': 'MY_JIRA_URL', 'email_env': 'MY_JIRA_EMAIL', 'api_token_env': 'MY_JIRA_TOKEN'}}}
url, email, token = mod.get_auth(config)
assert url == 'https://test.atlassian.net', f'url: {url}'
assert email == 'test@example.com', f'email: {email}'
assert token == 'tok123', f'token: {token}'
"

# get_auth: default env var names
check "jira: get_auth defaults to standard env var names" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
os.environ['JIRA_BASE_URL'] = 'https://default.atlassian.net'
os.environ['JIRA_EMAIL'] = 'default@example.com'
os.environ['JIRA_API_TOKEN'] = 'deftok'
mod = load('$ORCH_HOME/bin/orch-jira')
url, email, token = mod.get_auth({})
assert url == 'https://default.atlassian.net', f'url: {url}'
assert email == 'default@example.com', f'email: {email}'
assert token == 'deftok', f'token: {token}'
"

# get_auth: missing env var → dies
check_false "jira: get_auth dies when env var missing" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
for v in ['JIRA_BASE_URL', 'JIRA_EMAIL', 'JIRA_API_TOKEN']:
    os.environ.pop(v, None)
mod = load('$ORCH_HOME/bin/orch-jira')
mod.get_auth({})
"

# get_auth: strips trailing slash from base_url
check "jira: get_auth strips trailing slash" python3 -c "
import sys, os; sys.path.insert(0, '$TEMP_DIR')
from _load import load
os.environ['JIRA_BASE_URL'] = 'https://test.atlassian.net/'
os.environ['JIRA_EMAIL'] = 'test@test.com'
os.environ['JIRA_API_TOKEN'] = 'tok'
mod = load('$ORCH_HOME/bin/orch-jira')
url, _, _ = mod.get_auth({})
assert url == 'https://test.atlassian.net', f'url: {url}'
"

# resolve_title_prefix: tracker override (Section B)
check "jira: resolve_title_prefix uses tracker override" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_title_prefix({'tracker': {'title_prefix': '[OVER]'}, 'jira': {'title_prefix': '[J]'}})
assert r == '[OVER]', f'got {r}'
"

# resolve_title_prefix: jira fallback
check "jira: resolve_title_prefix falls back to jira.title_prefix" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_title_prefix({'jira': {'title_prefix': '[J]'}})
assert r == '[J]', f'got {r}'
"

# resolve_title_prefix: default [AI]
check "jira: resolve_title_prefix defaults to [AI]" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_title_prefix({})
assert r == '[AI]', f'got {r}'
"

# resolve_semantic_status: maps in_progress (Section F)
check "jira: resolve_semantic_status maps in_progress" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_semantic_status({'jira': {'status': {'in_progress': 'Working On It'}}}, 'in_progress')
assert r == 'Working On It', f'got {r}'
"

# resolve_semantic_status: maps done
check "jira: resolve_semantic_status maps done" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_semantic_status({'jira': {'status': {'done': 'Closed'}}}, 'done')
assert r == 'Closed', f'got {r}'
"

# resolve_semantic_status: handles hyphenated input (in-progress → in_progress)
check "jira: resolve_semantic_status handles hyphens" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_semantic_status({'jira': {'status': {'in_progress': 'Active'}}}, 'in-progress')
assert r == 'Active', f'got {r}'
"

# resolve_semantic_status: passes through literal (non-semantic) names
check "jira: resolve_semantic_status passes through literals" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_semantic_status({}, 'My Custom Status')
assert r == 'My Custom Status', f'got {r}'
"

# resolve_semantic_status: uses defaults when not configured
check "jira: resolve_semantic_status uses defaults" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
assert mod.resolve_semantic_status({}, 'todo') == 'To Do'
assert mod.resolve_semantic_status({}, 'in_progress') == 'In Progress'
assert mod.resolve_semantic_status({}, 'done') == 'Done'
assert mod.resolve_semantic_status({}, 'blocked') == 'Blocked'
"

# resolve_labels: merge all sources (Section B)
check "jira: resolve_labels merges agnostic + specific + CLI" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
config = {'tracker': {'labels': ['shared']}, 'jira': {'labels': ['jira-specific']}}
r = mod.resolve_labels(config, 'cli-label')
assert 'shared' in r, f'missing shared: {r}'
assert 'jira-specific' in r, f'missing jira-specific: {r}'
assert 'cli-label' in r, f'missing cli-label: {r}'
"

# resolve_labels: dedup
check "jira: resolve_labels deduplicates case-insensitive" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
r = mod.resolve_labels({'tracker': {'labels': ['Dup']}, 'jira': {'labels': ['dup']}})
assert len(r) == 1, f'expected 1, got {len(r)}: {r}'
"

# subtask_issue_type: canonical key (Section E)
check "jira: config reads jira.subtask_issue_type" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
config = {'jira': {'subtask_issue_type': 'Story'}}
r = mod.config_get(config, 'jira.subtask_issue_type', '')
assert r == 'Story', f'got {r}'
"

# subtask_issue_type: legacy fallback
check "jira: subtask type falls back to jira.subtask_type" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
config = {'jira': {'subtask_type': 'Bug'}}
canonical = mod.config_get(config, 'jira.subtask_issue_type', '')
legacy = mod.config_get(config, 'jira.subtask_type', 'Sub-task')
result = canonical if canonical else legacy
assert result == 'Bug', f'got {result}'
"

# subtask_issue_type: default Sub-task
check "jira: subtask type defaults to Sub-task" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
config = {'jira': {}}
canonical = mod.config_get(config, 'jira.subtask_issue_type', '')
legacy = mod.config_get(config, 'jira.subtask_type', 'Sub-task')
result = canonical if canonical else legacy
assert result == 'Sub-task', f'got {result}'
"

# text_to_adf: basic conversion
check "jira: text_to_adf produces valid ADF" python3 -c "
import sys; sys.path.insert(0, '$TEMP_DIR')
from _load import load
mod = load('$ORCH_HOME/bin/orch-jira')
adf = mod.text_to_adf('Hello world')
assert adf['type'] == 'doc'
assert adf['version'] == 1
assert adf['content'][0]['type'] == 'paragraph'
assert adf['content'][0]['content'][0]['text'] == 'Hello world'
"

# log_jira_event: dual logging (Section G)
check "jira: log_jira_event writes to both files" python3 -c "
import sys, os, json, tempfile; sys.path.insert(0, '$TEMP_DIR')
from _load import load
tmpdir = tempfile.mkdtemp()
os.environ['ORCH_STATE_DIR'] = tmpdir
mod = load('$ORCH_HOME/bin/orch-jira')
mod.log_jira_event({'type': 'test_event', 'issue_key': 'PROJ-1', 'title': 'Test', 'run_id': 'r1'})
jl = [json.loads(l) for l in open(os.path.join(tmpdir, 'state', 'jira.jsonl')).readlines()]
tl = [json.loads(l) for l in open(os.path.join(tmpdir, 'state', 'tracker.jsonl')).readlines()]
assert jl[0]['type'] == 'test_event'
assert 'timestamp' in jl[0]
assert tl[0]['tracker_type'] == 'jira'
assert tl[0]['action'] == 'test_event'
assert tl[0]['issue_key'] == 'PROJ-1'
assert 'timestamp' in tl[0]
"

# If LINEAR_API_KEY is set, test auth
if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    echo ""
    echo "=== Linear API auth (live) ==="
    check "orch-linear viewer" "$ORCH_HOME/bin/orch-linear" viewer
fi

# If JIRA env vars are all set, test auth
if [[ -n "${JIRA_BASE_URL:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    echo ""
    echo "=== Jira API auth (live) ==="
    check "orch-jira viewer" "$ORCH_HOME/bin/orch-jira" viewer
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
