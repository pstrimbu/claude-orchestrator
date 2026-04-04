import Foundation

func showTimeOverlay(overlay: OverlayManager, clockify: ClockifyService, onUpdate: @escaping () -> Void) {
    func buildItems() -> [OverlayItem] {
        var items: [OverlayItem] = []

        items.append(OverlayItem(
            label: "Status: \(clockify.recording ? "\u{25cf} Recording" : "\u{25cb} Stopped")",
            value: clockify.formatElapsed(),
            dimmed: true
        ))
        items.append(OverlayItem(label: "", dimmed: true))

        items.append(OverlayItem(
            label: clockify.recording ? "[S] Stop Recording" : "[S] Start Recording",
            shortcut: "s",
            action: {
                if clockify.recording { clockify.stop() } else { clockify.start() }
                overlay.updateItems(buildItems())
                onUpdate()
            }
        ))

        items.append(OverlayItem(
            label: "[F] Flush to Clockify",
            shortcut: "f",
            action: {
                overlay.close()
                Task {
                    _ = try? await clockify.flush()
                    await MainActor.run { onUpdate() }
                }
            }
        ))

        items.append(OverlayItem(label: "", dimmed: true))
        items.append(OverlayItem(label: "Clockify: \(clockify.enabled ? "Configured" : "Not configured")", dimmed: true))

        if !clockify.enabled {
            items.append(OverlayItem(label: "Set CLOCKIFY_API_KEY in .env to enable", dimmed: true))
        }

        items.append(OverlayItem(label: "", dimmed: true))

        items.append(OverlayItem(
            label: "[R] Load Recent Entries",
            shortcut: "r",
            action: {
                overlay.setLoading(true)
                Task {
                    let entries = await clockify.getRecentEntries(limit: 5)
                    await MainActor.run {
                        overlay.setLoading(false)
                        if entries.isEmpty {
                            overlay.showMessage("No recent entries")
                            return
                        }
                        var newItems = buildItems()
                        if let idx = newItems.firstIndex(where: { $0.label.contains("Recent Entries") }) {
                            newItems.remove(at: idx)
                            newItems.insert(OverlayItem(label: "Recent Entries:", dimmed: true), at: idx)
                            for (offset, e) in entries.enumerated() {
                                newItems.insert(OverlayItem(
                                    label: "  \(e.description ?? "(no description)")",
                                    value: e.timeInterval?.duration ?? "",
                                    dimmed: true
                                ), at: idx + 1 + offset)
                            }
                        }
                        overlay.updateItems(newItems)
                    }
                }
            }
        ))

        return items
    }

    overlay.show(OverlayConfig(
        title: "Time Tracking",
        items: buildItems(),
        onClose: onUpdate,
        footer: "[S] Start/Stop  [F] Flush  [R] Recent",
        anchor: "status-time"
    ))
}
