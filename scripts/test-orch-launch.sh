#!/usr/bin/env bash
# test-orch-launch.sh — bin/orch's argument handling, run under macOS's stock
# /bin/bash (3.2), which is what the app's F5 relaunch gets.
#
# Regression: `orch <project> --resume <id>` died on "${ARGS[-1]}: bad array
# subscript" before opening anything, so F5 closed the window and nothing
# reopened (2026-11-16).
#
# Hermetic: bin/orch is copied into a throwaway repo layout with a fake app
# binary, HOME is a temp dir (no credential hook, no real ~/.claude.json), and
# open/codesign/security are stubs. Nothing is launched.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/repo/bin" "$T/repo/app-native/Sources" "$T/repo/app-native/.build/debug" \
         "$T/home" "$T/stub" "$T/proj"
cp "$REPO/bin/orch" "$T/repo/bin/orch"
cp /usr/bin/true "$T/repo/app-native/.build/debug/orch"
# `open` records its arguments, one per line; the others just succeed.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/open.args"\n' "$T" > "$T/stub/open"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/codesign"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/security"
chmod +x "$T/stub/"*
PROJ="$(cd "$T/proj" && pwd -P)"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; shift; printf '        %s\n' "$@"; fail=$((fail + 1)); }

# run_orch ARGS... — exit status in $rc, stderr in $T/err, what `open` got in $T/open.args
run_orch() {
  rm -f "$T/open.args"
  (cd "$PROJ" && env -i HOME="$T/home" PATH="$T/stub:/usr/bin:/bin:/usr/sbin:/sbin" \
     /bin/bash "$T/repo/bin/orch" "$@" >"$T/out" 2>"$T/err" </dev/null)
  rc=$?
  # `open` is backgrounded by the script; give it a moment to write.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$T/open.args" ] && break; sleep 0.1
  done
}

# expect DESC -- ORCH ARGS... -- EXPECTED TAIL OF open's ARGS (after "--args")
expect() {
  local desc="$1"; shift; shift
  local args=() want=()
  while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  want=("$@")
  run_orch ${args[@]+"${args[@]}"}
  if [ $rc -ne 0 ]; then bad "$desc" "exit $rc: $(cat "$T/err")"; return; fi
  if [ ! -s "$T/open.args" ]; then bad "$desc" "open was never called"; return; fi
  local got; got="$(sed -n '/^--args$/,$p' "$T/open.args" | sed 1d | tr '\n' '|')"
  local exp; exp="$(printf '%s|' ${want[@]+"${want[@]}"})"
  if [ "$got" = "$exp" ]; then ok "$desc"; else bad "$desc" "want: $exp" "got:  $got"; fi
}

echo "=== bin/orch argument handling under $(/bin/bash -c 'echo "bash $BASH_VERSION"') ==="
ID=11111111-2222-3333-4444-555555555555
expect "F5 relaunch: <project> --resume <id>" -- "$PROJ" --resume "$ID" -- "$PROJ" --resume "$ID"
expect "F5 relaunch: <project> --continue"    -- "$PROJ" --continue      -- "$PROJ" --continue
expect "flag before the project path"         -- --continue "$PROJ"      -- "$PROJ" --continue
expect "--resume <id> before the project"     -- -r "$ID" "$PROJ"        -- "$PROJ" -r "$ID"
expect "no project path: current directory"   -- --continue              -- "$PROJ" --continue
expect "no arguments at all"                  -- -- "$PROJ"
expect "background flag after the project"    -- "$PROJ" --background    -- "$PROJ" --background

# Every window shares one bundle id, so a privacy grant ("Allow" for Desktop,
# camera…) made in one project covers all of them, worker worktrees included.
mkdir -p "$T/proj2"; PROJ2="$(cd "$T/proj2" && pwd -P)"
run_orch "$PROJ2"
id1="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJ/.orch/proj.app/Contents/Info.plist" 2>&1)"
id2="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PROJ2/.orch/proj2.app/Contents/Info.plist" 2>&1)"
name2="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PROJ2/.orch/proj2.app/Contents/Info.plist" 2>&1)"
if [ "$id1" = "com.orch.session" ] && [ "$id2" = "$id1" ]; then ok "all projects share one bundle id"
else bad "all projects share one bundle id" "proj: $id1" "proj2: $id2"; fi
if [ "$name2" = "proj2" ]; then ok "Dock name is still the project"; else bad "Dock name is still the project" "got: $name2"; fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ $fail -eq 0 ]
