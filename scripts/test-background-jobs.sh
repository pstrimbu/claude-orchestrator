#!/usr/bin/env bash
# test-background-jobs.sh — BackgroundJobs (the status bar's background-command
# chip) against real processes: it compiles BackgroundJobs.swift into a small
# harness that starts children shaped like Claude Code's Bash-tool shells and
# checks which ones are reported.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

cat > "$T/main.swift" <<'EOF'
import Foundation

var pass = 0, fail = 0
func check(_ desc: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("  PASS: \(desc)"); pass += 1 }
    else { print("  FAIL: \(desc)\(detail.isEmpty ? "" : "\n        \(detail)")"); fail += 1 }
}

// Claude's wrapper: source the shell snapshot, then eval the command.
func claudeShell(_ cmd: String) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    let quoted = cmd.replacingOccurrences(of: "'", with: "'\\''")
    p.arguments = ["-c", "source /nonexistent/.claude/shell-snapshots/snapshot-zsh-1-x.sh 2>/dev/null || true && eval '\(quoted)' < /dev/null && pwd -P >| /dev/null"]
    try! p.run()
    return p
}
func plain(_ cmd: String) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    try! p.run()
    return p
}

let me = getpid()
let job = claudeShell("sleep 30 # it's a job")
let helper = plain("sleep 30")            // not a Bash-tool shell (like caffeinate)
Thread.sleep(forTimeInterval: 0.3)

check("a fresh command is not reported yet (minAge)",
      BackgroundJobs.running(under: me, minAge: 5).isEmpty)

let jobs = BackgroundJobs.running(under: me, minAge: 0)
check("exactly the Bash-tool shell is reported", jobs.map(\.pid) == [job.processIdentifier],
      "got \(jobs)")
check("its command is unwrapped and unquoted", jobs.first?.command == "sleep 30 # it's a job",
      "got \(jobs.first?.command ?? "nil")")

job.terminate(); job.waitUntilExit()
check("a finished command disappears", BackgroundJobs.running(under: me, minAge: 0).isEmpty)
helper.terminate()

check("no parent pid: nothing", BackgroundJobs.running(under: 0).isEmpty)
check("wrapper without eval falls back to the whole script",
      BackgroundJobs.command(fromWrapper: "just a script") == "just a script")

print("\n=== Results: \(pass) passed, \(fail) failed ===")
exit(fail == 0 ? 0 : 1)
EOF

swiftc -o "$T/harness" "$REPO/app-native/Sources/Orch/Services/BackgroundJobs.swift" "$T/main.swift" 2>&1 \
  | grep -v "warning:" | grep . && { echo "compile failed"; exit 1; }
echo "=== BackgroundJobs ==="
"$T/harness"
