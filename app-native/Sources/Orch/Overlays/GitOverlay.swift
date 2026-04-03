import Foundation

func showGitOverlay(overlay: OverlayManager, config: Config, session: ClaudeSession, onUpdate: @escaping () -> Void) {
    var items: [OverlayItem] = []

    let git: (String) -> String? = { cmd in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["bash", "-c", cmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.projectPath)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let branch = git("git rev-parse --abbrev-ref HEAD"), !branch.isEmpty {
        let statusOut = git("git status --short") ?? ""
        let changedFiles = statusOut.isEmpty ? [] : statusOut.components(separatedBy: .newlines)
        let ahead = getAheadBehind(git)

        items.append(OverlayItem(label: "Branch: \(branch)", dimmed: true))
        items.append(OverlayItem(label: "\(changedFiles.count) changed files\(ahead)", dimmed: true))
        items.append(OverlayItem(label: "", dimmed: true))

        if !changedFiles.isEmpty {
            items.append(OverlayItem(label: "Changed Files:", dimmed: true))
            for file in changedFiles.prefix(15) {
                items.append(OverlayItem(label: "  \(file)", dimmed: true))
            }
            if changedFiles.count > 15 {
                items.append(OverlayItem(label: "  ... and \(changedFiles.count - 15) more", dimmed: true))
            }
            items.append(OverlayItem(label: "", dimmed: true))
        }

        items.append(OverlayItem(label: "Ask Claude to Commit", action: {
            session.write("/commit\n")
            overlay.close()
        }))

        items.append(OverlayItem(label: "Ask Claude to Review Changes", action: {
            session.write("Review the current git diff and tell me if the changes look good.\n")
            overlay.close()
        }))

        items.append(OverlayItem(label: "Ask Claude to Create PR", action: {
            session.write("Create a pull request for the current branch.\n")
            overlay.close()
        }))

        items.append(OverlayItem(label: "", dimmed: true))

        items.append(OverlayItem(label: "Git Stash", action: {
            if let _ = git("git stash") {
                overlay.showMessage("Stashed changes")
                onUpdate()
            } else {
                overlay.showMessage("Error stashing")
            }
        }))

        items.append(OverlayItem(label: "Git Stash Pop", action: {
            if let _ = git("git stash pop") {
                overlay.showMessage("Popped stash")
                onUpdate()
            } else {
                overlay.showMessage("Error popping stash")
            }
        }))
    } else {
        items.append(OverlayItem(label: "Not a git repository", dimmed: true))
    }

    overlay.show(OverlayConfig(
        title: "Git",
        items: items,
        onClose: onUpdate,
        footer: "[Enter] Select  [Esc] Close",
        anchor: "status-git"
    ))
}

private func getAheadBehind(_ git: (String) -> String?) -> String {
    guard let out = git("git rev-list --left-right --count HEAD...@{upstream}"),
          !out.isEmpty else { return "" }
    let parts = out.components(separatedBy: "\t").compactMap { Int($0) }
    guard parts.count == 2 else { return "" }
    var result: [String] = []
    if parts[0] > 0 { result.append("\u{2191}\(parts[0])") }
    if parts[1] > 0 { result.append("\u{2193}\(parts[1])") }
    return result.isEmpty ? "" : "  \(result.joined(separator: " "))"
}
