import Foundation
import AppKit

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

    items.append(OverlayItem(
        label: "[S] Completion Sound: \(config.soundOnCompletion ? "On" : "Off")",
        shortcut: "s",
        action: {
            let on = !config.soundOnCompletion
            config.setSoundOnCompletion(on)
            if on { NSSound(named: "Glass")?.play() }   // preview the sound
            overlay.showMessage("Completion sound \(on ? "on" : "off")")
            onUpdate()
        }
    ))

    overlay.show(OverlayConfig(
        title: "Project",
        items: items,
        onClose: onUpdate,
        width: 65,
        footer: "[W] Wizard  [E] Editor  [F] Finder  [S] Sound",
        anchor: "status-project"
    ))
}
