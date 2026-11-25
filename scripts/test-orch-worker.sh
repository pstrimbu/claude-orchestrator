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
[ -f "$HOME/.config/orch/sessions/p11-wt-w1.json" ] && echo "$out" | grep -q "isn't writable" \
  && [ "$(find "$wt" -name '*.txt' | wc -l | tr -d ' ')" = 300 ] && git -C "$wt" status >/dev/null 2>&1 \
  && ok "an undeletable directory refuses before anything is deleted; tree, registration and registry kept" \
  || bad "unexpected: $out ($(find "$wt" -name '*.txt' | wc -l) files left)"

echo "untracked files count whatever status.showUntrackedFiles says"
new_repo p12; wt="$T/p12-wt-w1"; git -C "$T/p12" config status.showUntrackedFiles no; echo new > "$wt/notes.md"
! "$ORCH_WORKER" rm "$T/p12" w1 >/dev/null 2>&1 && [ -f "$wt/notes.md" ] && ok "untracked file kept" || bad "untracked file deleted"

echo "round 2: lsof warnings, late ps failures, prefix-sharing windows"
new_repo p14; wt="$T/p14-wt-w1"; mkdir -p "$wt/.orch/locked/deep"
( cd "$wt/.orch/locked/deep" && exec sleep 30 ) & other=$!; pids+=($other); sleep 0.3
chmod 000 "$wt/.orch/locked"
out="$("$ORCH_WORKER" rm "$T/p14" w1 2>&1)" && bad "removed past an unreadable directory ($out)" || true
chmod 755 "$wt/.orch/locked" 2>/dev/null || true
[ -f "$wt/d1/f1.txt" ] && git -C "$T/p14" worktree list | grep -qF "$wt" && echo "$out" | grep -q "lsof" \
  && ok "an lsof warning stops the removal; tree kept" || bad "unexpected: $out"
kill -KILL "$other" 2>/dev/null || true
new_repo p15; wt="$T/p15-wt-w1"; window "$wt"; w=$last
cat > "$T/shim/ps" <<SH
#!/bin/sh
case "\$*" in *lstart=*-p*) exit 1 ;; esac
exec /bin/ps "\$@"
SH
chmod +x "$T/shim/ps"
out="$(PATH="$T/shim:$PATH" "$ORCH_WORKER" rm "$T/p15" w1 2>&1)" && bad "removed though ps couldn't identify the window ($out)" || true
[ -f "$wt/d1/f1.txt" ] && echo "$out" | grep -q "not sure" && ok "a late ps failure stops the removal; tree kept" || bad "unexpected: $out"
kill -TERM "$w" 2>/dev/null || true
new_repo p16; wt="$T/p16-wt-w1"; mkdir -p "$T/p16-wt-w10/.orch"; window "$T/p16-wt-w10"; w10=$last
echo "$w10" > "$wt/.orch/orch.pid"                         # a stale pid file naming w10's window
out="$("$ORCH_WORKER" rm "$T/p16" w1 2>&1)" || true
kill -0 "$w10" 2>/dev/null && ok "another worktree's window (w10) is never taken for w1's" || bad "w10's window was stopped ($out)"
kill -TERM "$w10" 2>/dev/null || true

echo "round 3: index flags, and a delete that would stop partway"
for flag in assume-unchanged skip-worktree; do
  new_repo p17; wt="$T/p17-wt-w1"
  git -C "$wt" update-index --$flag d4/f4.txt; echo "hidden edit" > "$wt/d4/f4.txt"
  out="$("$ORCH_WORKER" rm "$T/p17" w1 2>&1)" && bad "$flag: removed a hidden edit ($out)" || true
  grep -q "hidden edit" "$wt/d4/f4.txt" 2>/dev/null && ok "$flag: the hidden edit is kept" || bad "$flag: edit lost ($out)"
done
new_repo p18; wt="$T/p18-wt-w1"; chflags uchg "$wt/d5/f5.txt"
out="$("$ORCH_WORKER" rm "$T/p18" w1 2>&1)" && bad "removed past a locked file ($out)" || true
chflags nouchg "$wt/d5/f5.txt" 2>/dev/null || true
[ "$(find "$wt" -name '*.txt' | wc -l | tr -d ' ')" = 300 ] && echo "$out" | grep -q "locked" \
  && ok "a locked file refuses before anything is deleted" || bad "unexpected: $out"

echo "round 4: a large index (no SIGPIPE through pipefail)"
r="$T/p19"; mkdir -p "$r/big"; git -C "$r" init -q -b main
git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
( cd "$r/big" && for i in $(seq -w 0 11999); do : > "f$i"; done ); echo base > "$r/big/f00000"
git -C "$r" add -A; git -C "$r" commit -qm base; git -C "$r" worktree add -q -b wt/w1 "$r-wt-w1" main
git -C "$r-wt-w1" update-index --assume-unchanged big/f00000; echo "UNCOMMITTED" > "$r-wt-w1/big/f00000"
out="$("$ORCH_WORKER" rm "$r" w1 2>&1)" && bad "large index: removed a hidden edit ($out)" || true
grep -q UNCOMMITTED "$r-wt-w1/big/f00000" 2>/dev/null && ok "large index: the hidden edit is kept" || bad "large index: edit lost"
for i in $(seq 1 40); do git -C "$r" worktree add -q -b "wt/pad$i" "$r-pad$i" main 2>/dev/null; done   # a long worktree list
out="$("$ORCH_WORKER" "$r" w1 --agent codex --no-launch 2>&1)" && ok "a valid worktree is still reused with a long worktree list" || bad "valid worktree refused: $out"

echo "round 5: a read-only parent"
mkdir -p "$T/nest"; r="$T/nest/p20"; mkdir -p "$r"; git -C "$r" init -q -b main
git -C "$r" config user.email t@example.invalid; git -C "$r" config user.name t
echo a > "$r/a"; git -C "$r" add -A; git -C "$r" commit -qm base; git -C "$r" worktree add -q -b wt/w1 "$r-wt-w1" main
chmod 0555 "$T/nest"
out="$("$ORCH_WORKER" rm "$r" w1 2>&1)" && bad "removed under a read-only parent ($out)" || true
chmod 0755 "$T/nest"
[ -f "$r-wt-w1/a" ] && git -C "$r-wt-w1" status >/dev/null 2>&1 && echo "$out" | grep -q "parent" \
  && ok "a read-only parent refuses before anything is deleted; tree still a working worktree" || bad "unexpected: $out"

echo "Loops registration (D-1222): only 401/403 aborts; 409 session_closing, other errors and a down API launch"
loops_cli="${LOOPS_CLI_UNDER_TEST:-/Users/peterstrimbu/dev/loops/portal/bin/loops}"
if [ ! -x "$loops_cli" ]; then
  echo "  SKIP: no loops CLI at $loops_cli"
else
  # The real CLI against a fake API: GETs succeed, POST /sessions/register gets the given status.
  cat > "$T/fake_api.py" <<'PY'
import http.server, json, sys
code, err = int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, c, obj):
        b = json.dumps(obj).encode()
        self.send_response(c); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.reply(200, [])
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        self.reply(code, {"detail": {"error": err, "message": f"fake {err}"}})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  # Stand-in for bin/orch: orch-worker execs "$(dirname "$0")/orch", so run a copy beside a fake.
  mkdir -p "$T/regbin"; cp "$ORCH_WORKER" "$T/regbin/"
  printf '#!/bin/sh\necho "LAUNCHED $*"\n' > "$T/regbin/orch"; chmod +x "$T/regbin/orch"
  new_repo reg
  port=18$((RANDOM % 800 + 100))
  reg() {   # reg NAME STATUS ERROR -> $out, $rc
    local p=$((port++))
    python3 "$T/fake_api.py" "$p" "$2" "$3" & pids+=($!); local api=$!; sleep 0.5
    rc=0; out="$(ORCH_LOOPS_CLI="$loops_cli" LOOPS_API="http://127.0.0.1:$p/api" LOOPS_DATA_DIR="$T/loops-data" \
      "$T/regbin/orch-worker" "$T/reg" "$1" --agent codex 2>&1)" || rc=$?
    { kill "$api"; wait "$api"; } 2>/dev/null || true
  }
  for s in 401 403; do
    reg "r$s" "$s" forbidden
    [ "$rc" -ne 0 ] && ! grep -q LAUNCHED <<<"$out" && grep -q "not launching" <<<"$out" \
      && ok "$s aborts without a window" || bad "$s: rc=$rc $out"
  done
  reg r409 409 session_closing
  [ "$rc" -eq 0 ] && grep -q LAUNCHED <<<"$out" && grep -q "409" <<<"$out" \
    && ok "409 session_closing warns and launches" || bad "409: rc=$rc $out"
  reg r422 422 invalid
  [ "$rc" -eq 0 ] && grep -q LAUNCHED <<<"$out" && ok "another refusal (422) warns and launches" || bad "422: rc=$rc $out"
  rc=0; out="$(ORCH_LOOPS_CLI="$loops_cli" LOOPS_API="http://127.0.0.1:1/api" LOOPS_DATA_DIR="$T/loops-data" \
    "$T/regbin/orch-worker" "$T/reg" rdown --agent codex 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && grep -q LAUNCHED <<<"$out" && grep -q "queued" <<<"$out" \
    && ok "an unreachable API queues the registration and launches" || bad "API down: rc=$rc $out"
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
