import Darwin
import Foundation

/// Shell commands Claude Code is running for this window: background jobs
/// (`run_in_background`, Monitor) and any long foreground command.
///
/// Claude Code reports background *agents* through its subagent status line,
/// but nothing for background *shells*, and they print nothing to the terminal,
/// so the window looks idle while they run. Each Bash-tool command is a direct
/// child shell of the claude process whose script sources Claude's shell
/// snapshot (`~/.claude/shell-snapshots/snapshot-…`), which is what we match.
/// Read straight from the kernel (libproc/sysctl) so polling every couple of
/// seconds doesn't spawn `ps`.
enum BackgroundJobs {
    struct Job: Equatable {
        let pid: pid_t
        let command: String     // the command Claude ran, best effort
        let startedAt: Date
    }

    /// Running Bash-tool commands under `parent` that have been going for at
    /// least `minAge` seconds (so a quick foreground command doesn't flash the
    /// indicator). Oldest first.
    static func running(under parent: pid_t, minAge: TimeInterval = 5) -> [Job] {
        guard parent > 0 else { return [] }
        let now = Date()
        return childPids(of: parent).compactMap { pid -> Job? in
            guard let args = arguments(of: pid),
                  args.contains("shell-snapshots/snapshot-"),
                  let started = startTime(of: pid),
                  now.timeIntervalSince(started) >= minAge
            else { return nil }
            return Job(pid: pid, command: command(fromWrapper: args), startedAt: started)
        }.sorted { $0.startedAt < $1.startedAt }
    }

    /// The user-visible command inside Claude's wrapper script, which runs it
    /// as `eval '<command>' < /dev/null`. Falls back to the whole script.
    static func command(fromWrapper script: String) -> String {
        guard let start = script.range(of: "eval '") else { return script }
        let rest = script[start.upperBound...]
        let end = rest.range(of: "' < /dev/null") ?? rest.range(of: "'")
        let body = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        return body.replacingOccurrences(of: "'\\''", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Kernel lookups

    private static func childPids(of parent: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes {
            proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
        }
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n))).filter { $0 > 0 }
    }

    private static func startTime(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                    + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// argv joined with spaces, from KERN_PROCARGS2:
    /// [argc: Int32][exec path\0][\0 padding][argv[0]\0 … argv[argc-1]\0][env…]
    private static func arguments(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }      // exec path
        while i < size && buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while i < size && args.count < Int(argc) {
            var j = i
            while j < size && buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args.joined(separator: " ")
    }
}
