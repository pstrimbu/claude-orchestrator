#!/usr/bin/env bash
# test-orch-worker.sh — orch-worker rm/start against temporary repos (2026-11-12).
#
# A live window kept writing into .orch/ while `rm` deleted the tree, so git's
# delete failed partway and git dropped the worktree's metadata anyway; then
# `orch-worker <repo> <name>` relaunched a reviewer into that half-deleted folder.
# Everything here runs under a temporary HOME and temporary repos: no Loops
# registration (no ~/dev/loops under the fake HOME), no real orch windows.
set -euo pipefail

ORCH_WORKER="$(cd "$(dirname "$0")/.." && pwd)/bin/orch-worker"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
export HOME="$T/home"; mkdir -p "$HOME/.config/orch/sessions" "$HOME/.codex"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

new_repo() {   # new_repo NAME -> repo with 300 tracked files and worktree NAME-wt-w1
  local r="$T/$1"
  rm -rf "$r" "$r-wt-w1"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
  for i in $(seq 1 300); do mkdir -p "$r/d$((i % 10))"; echo "$i" > "$r/d$((i % 10))/f$i.txt"; done
  git -C "$r" add -A; git -C "$r" commit -qm base
  git -C "$r" worktree add -q -b wt/w1 "$r-wt-w1" main
  mkdir -p "$r-wt-w1/.orch"
}

# A stand-in for the orch window: its command line is ".../MacOS/orch <worktree>"
# (what orch-worker's window_pid looks for), it keeps writing into .orch/ like
# the real app, and with FAKE_RUN it runs that command as its own child.
mkdir -p "$T/fake.app/Contents/MacOS"
cat > "$T/fake.app/Contents/MacOS/orch" <<'SH'
#!/usr/bin/env bash
wt="$1"
echo $$ > "$wt/.orch/orch.pid"
trap '[ -n "${FAKE_TERM_EDIT:-}" ] && echo "written on shutdown" >> "$FAKE_TERM_EDIT"; exit 0' TERM
[ -n "${FAKE_RUN:-}" ] && { bash -c "$FAKE_RUN" > "$wt.run.out" 2>&1 & }
if [ -n "${FAKE_CHILD:-}" ]; then      # a writer that outlives the window
  ( trap '' TERM; while :; do echo x > "$wt/.orch/child.json" 2>/dev/null; sleep 0.01; done ) &
  echo $! > "$wt.child.pid"
fi
i=0
while :; do
  mkdir -p "$wt/.orch" 2>/dev/null && echo "$i" > "$wt/.orch/status.json" 2>/dev/null
  i=$((i + 1)); sleep 0.005
done
SH
chmod +x "$T/fake.app/Contents/MacOS/orch"
window() { "$T/fake.app/Contents/MacOS/orch" "$1" & last=$!; pids+=($last); sleep 0.3; }

echo "rm closes the window first, so the removal completes"
new_repo p1; wt="$T/p1-wt-w1"; window "$wt"; w=$last
out="$("$ORCH_WORKER" rm "$T/p1" w1 2>&1)" || true
[ ! -e "$wt" ] && ok "tree fully removed ($out)" || bad "tree left behind: $(find "$wt" | head -3) ($out)"
! kill -0 "$w" 2>/dev/null && ok "window closed" || bad "window still running"
! git -C "$T/p1" worktree list | grep -qF "$wt" && ok "worktree unregistered" || bad "still registered"
git -C "$T/p1" rev-parse -q --verify wt/w1 >/dev/null && ok "branch kept" || bad "branch gone"

echo "a session removing itself: a detached helper closes the window, then removes"
new_repo p2; wt="$T/p2-wt-w1"
FAKE_RUN="'$ORCH_WORKER' rm '$T/p2' w1" window "$wt"; w=$last
for _ in $(seq 1 100); do [ -e "$wt" ] || break; sleep 0.1; done
[ ! -e "$wt" ] && ok "tree fully removed" || bad "tree left behind: $(find "$wt" | head -3)"
! kill -0 "$w" 2>/dev/null && ok "window closed" || bad "window still running"
grep -q "after its window closes" "$wt.run.out" && ok "handed off to the helper" || bad "no handoff: $(cat "$wt.run.out")"
for _ in $(seq 1 50); do grep -q "^removed $wt" "$HOME/.config/orch/orch-worker.log" 2>/dev/null && break; sleep 0.1; done
grep -q "^removed $wt" "$HOME/.config/orch/orch-worker.log" && ok "helper logged the removal" || bad "helper log: $(cat "$HOME/.config/orch/orch-worker.log" 2>/dev/null)"

echo "rm refuses uncommitted work and a folder git can't read"
new_repo p3; wt="$T/p3-wt-w1"; echo edit >> "$wt/d1/f1.txt"
! "$ORCH_WORKER" rm "$T/p3" w1 >/dev/null 2>&1 && [ -f "$wt/d1/f1.txt" ] && ok "uncommitted edit kept" || bad "dirty tree removed"
new_repo p4; wt="$T/p4-wt-w1"; rm -rf "$T/p4/.git/worktrees/p4-wt-w1"; rm "$wt/d2/f2.txt"
n="$(find "$wt" -type f | wc -l)"
out="$("$ORCH_WORKER" rm "$T/p4" w1 2>&1)" && bad "broken folder accepted ($out)" || true
[ "$(find "$wt" -type f | wc -l)" = "$n" ] && echo "$out" | grep -q "isn't a working git worktree" \
  && ok "broken folder left untouched" || bad "broken folder touched ($out)"

echo "start never reuses a folder that isn't a working worktree"
out="$("$ORCH_WORKER" "$T/p4" w1 --agent codex --no-launch 2>&1)" && bad "reused a broken folder ($out)" || true
echo "$out" | grep -q "not reusing it" && ok "refused the half-deleted folder" || bad "unexpected: $out"
mkdir -p "$T/p5-wt-w1"; new_repo p6; mkdir -p "$T/p6-wt-x"; echo junk > "$T/p6-wt-x/file"
out="$("$ORCH_WORKER" "$T/p6" x --agent codex --no-launch 2>&1)" && bad "reused a plain folder ($out)" || true
[ "$(cat "$T/p6-wt-x/file")" = junk ] && ok "refused a plain folder, left it alone" || bad "plain folder touched"
new_repo p7
out="$("$ORCH_WORKER" "$T/p7" w1 --agent codex --no-launch 2>&1)" && ok "a valid existing worktree is still reused" || bad "valid worktree refused: $out"

echo "rm re-checks after the window closes, and waits for every writer"
new_repo p8; wt="$T/p8-wt-w1"
FAKE_TERM_EDIT="$wt/d1/f1.txt" window "$wt"
out="$("$ORCH_WORKER" rm "$T/p8" w1 2>&1)" && bad "removed after a shutdown edit ($out)" || true
grep -q "written on shutdown" "$wt/d1/f1.txt" 2>/dev/null && echo "$out" | grep -q "changed while its window closed" \
  && ok "a shutdown handler's edit is kept" || bad "edit lost or wrong reason: $out"
new_repo p9; wt="$T/p9-wt-w1"
FAKE_CHILD=1 window "$wt"; child="$(cat "$wt.child.pid")"; pids+=($child)
out="$("$ORCH_WORKER" rm "$T/p9" w1 2>&1)" || true
sleep 0.3
! kill -0 "$child" 2>/dev/null && ok "the window's child that ignores TERM is stopped too" || bad "child still running"
[ ! -e "$wt" ] && ok "so the removal completes ($out)" || bad "tree left behind: $(find "$wt" | head -3) ($out)"
new_repo p13; wt="$T/p13-wt-w1"
( cd "$wt/d1" && exec sleep 30 ) & other=$!; pids+=($other); sleep 0.3
out="$("$ORCH_WORKER" rm "$T/p13" w1 2>&1)" && bad "removed while another process works inside it ($out)" || true
[ -d "$wt/d1" ] && git -C "$T/p13" worktree list | grep -qF "$wt" && echo "$out" | grep -q "still in use" \
  && ok "an unrelated process inside the tree stops the removal; tree and registration kept" || bad "unexpected: $out"
kill -KILL "$other" 2>/dev/null || true

echo "rm fails closed when ps fails, and when the removal itself fails"
new_repo p10; wt="$T/p10-wt-w1"; window "$wt"; w=$last
mkdir -p "$T/shim"; printf '#!/bin/sh\nexit 1\n' > "$T/shim/ps"; chmod +x "$T/shim/ps"
out="$(PATH="$T/shim:$PATH" "$ORCH_WORKER" rm "$T/p10" w1 2>&1)" && bad "removed without seeing the window ($out)" || true
[ -d "$wt/d1" ] && kill -0 "$w" 2>/dev/null && echo "$out" | grep -q "ps failed" \
  && ok "an unobservable window refuses the removal" || bad "unexpected: $out"
kill -TERM "$w" 2>/dev/null || true
new_repo p11; wt="$T/p11-wt-w1"; echo '{"pid": ""}' > "$HOME/.config/orch/sessions/p11-wt-w1.json"
chmod 0555 "$wt/d3"
out="$("$ORCH_WORKER" rm "$T/p11" w1 2>&1)" && bad "a failed removal reported success ($out)" || true
chmod 0755 "$wt/d3" 2>/dev/null || true
[ -f "$HOME/.config/orch/sessions/p11-wt-w1.json" ] && echo "$out" | grep -q "couldn't fully remove" \
  && ok "a failed removal exits nonzero and keeps the session's registry entry" || bad "unexpected: $out"

echo "untracked files count whatever status.showUntrackedFiles says"
new_repo p12; wt="$T/p12-wt-w1"; git -C "$T/p12" config status.showUntrackedFiles no; echo new > "$wt/notes.md"
! "$ORCH_WORKER" rm "$T/p12" w1 >/dev/null 2>&1 && [ -f "$wt/notes.md" ] && ok "untracked file kept" || bad "untracked file deleted"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
