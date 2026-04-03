import Foundation

func showProjectOverlay(
    overlay: OverlayManager,
    config: Config,
    statusBar: StatusBarState,
    onTrackerRefresh: @escaping () -> Void,
    onUpdate: @escaping () -> Void
) {
    var items: [OverlayItem] = []

    items.append(OverlayItem(label: "Project: \(config.projectName)", dimmed: true))
    items.append(OverlayItem(label: "Path: \(config.projectPath)", dimmed: true))
    items.append(OverlayItem(label: "Project ID: \(config.projectId)", dimmed: true))
    items.append(OverlayItem(label: "Tracker: \(config.trackerType)", dimmed: true))
    items.append(OverlayItem(label: "Clockify: \(config.clockifyApiKey != nil ? "Configured" : "Not configured")", dimmed: true))
    items.append(OverlayItem(label: "", dimmed: true))

    // Git info
    let gitOpts: (String) -> String? = { cmd in
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

    if let branch = gitOpts("git rev-parse --abbrev-ref HEAD"), !branch.isEmpty {
        let status = gitOpts("git status --short") ?? ""
        let changedFiles = status.isEmpty ? 0 : status.components(separatedBy: .newlines).count
        let log = gitOpts("git log --oneline -5") ?? ""

        items.append(OverlayItem(label: "Branch: \(branch)", dimmed: true))
        items.append(OverlayItem(label: "Changed files: \(changedFiles)", dimmed: true))
        items.append(OverlayItem(label: "", dimmed: true))
        items.append(OverlayItem(label: "Recent Commits:", dimmed: true))
        for line in log.components(separatedBy: .newlines) where !line.isEmpty {
            items.append(OverlayItem(label: "  \(line)", dimmed: true))
        }
    } else {
        items.append(OverlayItem(label: "Git: not available", dimmed: true))
    }

    items.append(OverlayItem(label: "", dimmed: true))

    items.append(OverlayItem(label: "[W] Run Setup Wizard", shortcut: "w", action: {
        showProjectSetup(overlay: overlay, config: config, onConfigured: {
            onTrackerRefresh()
            onUpdate()
        }, onUpdate: onUpdate)
    }))

    items.append(OverlayItem(label: "[E] Open in Editor", shortcut: "e", action: {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["code", config.projectPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        overlay.showMessage("Opened in VS Code")
    }))

    items.append(OverlayItem(label: "[F] Open in Finder", shortcut: "f", action: {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [config.projectPath]
        try? proc.run()
        overlay.showMessage("Opened in Finder")
    }))

    overlay.show(OverlayConfig(
        title: "Project",
        items: items,
        onClose: onUpdate,
        width: 65,
        footer: "[W] Wizard  [E] Editor  [F] Finder",
        anchor: "status-project"
    ))
}
