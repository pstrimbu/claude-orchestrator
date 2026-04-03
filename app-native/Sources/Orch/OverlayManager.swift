import AppKit

struct OverlayItem {
    var label: String
    var value: String? = nil
    var dimmed: Bool = false
    var shortcut: String? = nil
    var action: (() -> Void)? = nil
    var editable: Bool = false
    var editValue: String? = nil
    var placeholder: String? = nil
    var onEdit: ((String) -> Void)? = nil
    var onSubmit: ((String) -> Void)? = nil
}

struct OverlayConfig {
    var title: String
    var items: [OverlayItem]
    var onClose: () -> Void
    var width: Int? = nil
    var footer: String? = nil
    var anchor: String? = nil
}

/// Bridges a closure to an NSMenuItem target/action
class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func invoke() { handler() }
}

class OverlayManager {
    private var activeAnchor: String?
    private var activeConfig: OverlayConfig?
    private var menuActions: [MenuAction] = []
    private weak var anchorView: NSView?
    var visible: Bool { activeAnchor != nil }

    /// Show a menu built from the config, anchored below the status bar
    func show(_ config: OverlayConfig) {
        // Toggle: same anchor open -> close
        if let current = activeAnchor, config.anchor != nil, current == config.anchor {
            close()
            return
        }

        activeConfig = config
        activeAnchor = config.anchor
        presentMenu(config.items, title: config.title, footer: config.footer)
    }

    func close() {
        activeAnchor = nil
        let onClose = activeConfig?.onClose
        activeConfig = nil
        menuActions = []
        onClose?()
    }

    func showMessage(_ msg: String, duration: TimeInterval = 2.0) {
        // Show as a brief re-pop with the message, then restore
        guard let config = activeConfig else { return }
        var items = config.items
        items.insert(OverlayItem(label: "\u{26a0} \(msg)", dimmed: true), at: 0)
        items.insert(OverlayItem(label: ""), at: 1)
        presentMenu(items, title: config.title, footer: config.footer)
    }

    func setLoading(_ isLoading: Bool) {
        guard let config = activeConfig else { return }
        if isLoading {
            presentMenu([OverlayItem(label: "Loading...", dimmed: true)], title: config.title, footer: nil)
        } else {
            presentMenu(config.items, title: config.title, footer: config.footer)
        }
    }

    func updateItems(_ newItems: [OverlayItem]) {
        guard var config = activeConfig else { return }
        config.items = newItems
        activeConfig = config
        presentMenu(newItems, title: config.title, footer: config.footer)
    }

    // MARK: - Title/footer mutation (used by setup wizards)

    var title: String {
        get { activeConfig?.title ?? "" }
        set {
            activeConfig?.title = newValue
        }
    }

    var footer: String? {
        get { activeConfig?.footer }
        set {
            activeConfig?.footer = newValue
        }
    }

    // MARK: - Menu building

    private func presentMenu(_ items: [OverlayItem], title: String, footer: String?) {
        menuActions = []
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false

        // Title header
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        titleItem.attributedTitle = NSAttributedString(string: title, attributes: titleAttrs)
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        // Items
        for item in items {
            if item.label.isEmpty && item.value == nil && item.action == nil {
                menu.addItem(NSMenuItem.separator())
                continue
            }

            // Editable items → show alert when clicked
            if item.editable {
                let menuItem = NSMenuItem(title: "\(item.label) \(item.editValue ?? item.placeholder ?? "")", action: nil, keyEquivalent: "")
                let editAction = MenuAction { [weak self] in
                    self?.showEditAlert(item: item)
                }
                menuItem.target = editAction
                menuItem.action = #selector(MenuAction.invoke)
                menuItem.isEnabled = true
                menuActions.append(editAction)
                menu.addItem(menuItem)
                continue
            }

            // Build display string
            var display = item.label
            if let value = item.value {
                // Pad to align values on the right
                let padding = max(1, 50 - item.label.count)
                display += String(repeating: " ", count: padding) + value
            }

            let menuItem = NSMenuItem(title: display, action: nil, keyEquivalent: "")

            if let shortcut = item.shortcut, shortcut.count == 1 {
                menuItem.keyEquivalent = shortcut.lowercased()
                menuItem.keyEquivalentModifierMask = []
            }

            if item.dimmed && item.action == nil {
                menuItem.isEnabled = false
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
                menuItem.attributedTitle = NSAttributedString(string: display, attributes: dimAttrs)
            } else if let action = item.action {
                let menuAction = MenuAction(action)
                menuItem.target = menuAction
                menuItem.action = #selector(MenuAction.invoke)
                menuItem.isEnabled = true
                menuActions.append(menuAction)

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                ]
                menuItem.attributedTitle = NSAttributedString(string: display, attributes: attrs)
            } else {
                menuItem.isEnabled = false
            }

            menu.addItem(menuItem)
        }

        // Footer
        if let footer = footer, !footer.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let footerItem = NSMenuItem(title: footer, action: nil, keyEquivalent: "")
            footerItem.isEnabled = false
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            footerItem.attributedTitle = NSAttributedString(string: footer, attributes: footerAttrs)
            menu.addItem(footerItem)
        }

        // Pop up below the status bar area
        if let window = NSApp.mainWindow ?? NSApp.windows.first,
           let contentView = window.contentView {
            // Position at top-left of content area (below title bar + status bar)
            let point = NSPoint(x: 10, y: contentView.bounds.height - 28)
            menu.popUp(positioning: nil, at: point, in: contentView)
        }

        // After menu closes, clean up
        DispatchQueue.main.async { [weak self] in
            self?.activeAnchor = nil
            self?.menuActions = []
        }
    }

    // MARK: - Edit alert for editable items

    private func showEditAlert(item: OverlayItem) {
        let alert = NSAlert()
        alert.messageText = item.label
        alert.informativeText = item.placeholder ?? ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = item.editValue ?? ""
        input.placeholderString = item.placeholder
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let value = input.stringValue
            item.onEdit?(value)
            item.onSubmit?(value)
        }
    }

    // MARK: - Keyboard handling (no-op for native menus)

    func handleKey(_ key: String) {
        // NSMenu handles its own keyboard navigation
    }
}
