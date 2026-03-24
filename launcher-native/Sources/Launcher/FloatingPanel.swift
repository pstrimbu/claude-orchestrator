import AppKit

/// Non-activating floating panel that never steals focus from other apps.
class FloatingPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isOpaque = false
        backgroundColor = NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        hasShadow = true

        // Round corners
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 6
        contentView?.layer?.masksToBounds = true
    }

    // Allow first mouse click to work (like acceptFirstMouse in Tauri)
    func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // Panel can become key to handle clicks, but won't activate the app
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
