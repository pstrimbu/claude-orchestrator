import AppKit
import SwiftUI

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
    var width: Int?
    var footer: String?
    var anchor: String?
}

class OverlayManager: ObservableObject {
    @Published var visible = false
    @Published var title = ""
    @Published var items: [OverlayItem] = []
    @Published var footer: String?
    @Published var selectedIdx = 0
    @Published var editing = false
    @Published var loading = false
    @Published var message: String?
    @Published var overlayWidth: Int?

    private var activeConfig: OverlayConfig?
    private var messageTimer: Timer?

    func show(_ config: OverlayConfig) {
        // Toggle: if same anchor is already open, close
        if visible, let current = activeConfig, let anchor = config.anchor, current.anchor == anchor {
            close()
            return
        }
        activeConfig = config
        title = config.title
        items = config.items
        footer = config.footer
        overlayWidth = config.width
        selectedIdx = 0
        editing = false
        loading = false
        message = nil
        visible = true
    }

    func close() {
        guard visible else { return }
        let onClose = activeConfig?.onClose
        activeConfig = nil
        visible = false
        selectedIdx = 0
        editing = false
        onClose?()
    }

    func showMessage(_ msg: String, duration: TimeInterval = 2.0) {
        message = msg
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.message = nil
        }
    }

    func setLoading(_ isLoading: Bool) {
        loading = isLoading
    }

    func updateItems(_ newItems: [OverlayItem]) {
        items = newItems
        editing = false
        if selectedIdx >= newItems.count {
            selectedIdx = max(0, newItems.count - 1)
        }
    }

    func handleKey(_ key: String) {
        guard visible else { return }

        if editing {
            handleEditKey(key)
            return
        }

        // Click events
        if key.hasPrefix("click:"), let idx = Int(key.dropFirst(6)) {
            guard idx >= 0, idx < items.count else { return }
            selectedIdx = idx
            let item = items[idx]
            if item.editable {
                editing = true
            } else {
                item.action?()
            }
            return
        }

        switch key {
        case "escape":
            close()
        case "up":
            selectedIdx = max(0, selectedIdx - 1)
        case "down":
            selectedIdx = min(items.count - 1, selectedIdx + 1)
        case "return":
            guard selectedIdx < items.count else { return }
            let item = items[selectedIdx]
            if item.editable {
                editing = true
            } else {
                item.action?()
            }
        default:
            if key.count == 1 {
                let selected = selectedIdx < items.count ? items[selectedIdx] : nil
                if selected?.editable == true {
                    editing = true
                    handleEditKey(key)
                    return
                }
                if let match = items.first(where: { $0.shortcut?.lowercased() == key.lowercased() && $0.action != nil }) {
                    match.action?()
                }
            }
        }
    }

    private func handleEditKey(_ key: String) {
        guard selectedIdx < items.count, items[selectedIdx].editable else {
            editing = false
            return
        }

        let current = items[selectedIdx].editValue ?? ""

        switch key {
        case "return":
            editing = false
            items[selectedIdx].onSubmit?(current)
        case "escape":
            editing = false
        case "backspace":
            items[selectedIdx].editValue = String(current.dropLast())
            items[selectedIdx].onEdit?(items[selectedIdx].editValue ?? "")
        case "up":
            editing = false
            selectedIdx = max(0, selectedIdx - 1)
        case "down":
            editing = false
            selectedIdx = min(items.count - 1, selectedIdx + 1)
        default:
            if key.count == 1, let scalar = key.unicodeScalars.first, scalar.value >= 32 {
                items[selectedIdx].editValue = current + key
                items[selectedIdx].onEdit?(items[selectedIdx].editValue ?? "")
            }
        }
    }
}
