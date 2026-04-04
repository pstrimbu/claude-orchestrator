import AppKit
import SwiftUI
import Combine

enum DockedEdge: String {
    case left, right, floating
}

/// Manages the floating panel: positioning, dragging, edge snapping, hover expand/collapse.
class PanelController {
    let panel: FloatingPanel
    let viewModel: LauncherViewModel

    private let collapsedWidth: CGFloat = 40
    private let expandedWidth: CGFloat = 520
    private let collapseDelayMs: TimeInterval = 0.4
    private let snapThreshold: CGFloat = 60
    private let titlebarHeight: CGFloat = 36
    private let dragThreshold: CGFloat = 4

    private var dockedEdge: DockedEdge = .right
    private var anchorY: CGFloat = 80
    private var pinnedScreenIndex: Int = 0  // index into NSScreen.screens

    private var collapseTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var transitioning = false

    private var pollTimerSource: DispatchSourceTimer?

    // Drag state
    private var isDragging = false
    private var isPendingDrag = false
    private var dragStartMouseLocation: NSPoint = .zero
    private var dragStartPanelOrigin: NSPoint = .zero

    init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 400),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        self.panel = panel

        let hostingView = NSHostingView(rootView:
            ContentView(viewModel: viewModel, onAddProject: { [weak self] in
                self?.showAddProjectDialog()
            })
        )
        panel.contentView = hostingView

        loadPosition()
        layoutPanel(expanded: false)
        setupMouseTracking()

        viewModel.$apps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.layoutPanel(expanded: self?.viewModel.isExpanded ?? false)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.layoutPanel(expanded: self.viewModel.isExpanded)
            }
            .store(in: &cancellables)

        panel.orderFrontRegardless()
    }

    // MARK: - Persistence

    private var positionFile: URL {
        ConfigStore.configDir.appendingPathComponent("launcher-position.json")
    }

    private func loadPosition() {
        guard let data = try? Data(contentsOf: positionFile),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edge = dict["edge"] as? String,
              let y = dict["y"] as? Double else {
            dockedEdge = .right
            anchorY = 80
            return
        }
        dockedEdge = DockedEdge(rawValue: edge) ?? .right
        anchorY = CGFloat(y)
        pinnedScreenIndex = dict["screen"] as? Int ?? 0
    }

    private func savePosition() {
        let dict: [String: Any] = ["edge": dockedEdge.rawValue, "y": anchorY, "screen": pinnedScreenIndex]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? FileManager.default.createDirectory(at: ConfigStore.configDir, withIntermediateDirectories: true)
            try? data.write(to: positionFile)
        }
    }

    // MARK: - Layout

    private var pinnedScreen: NSScreen {
        let screens = NSScreen.screens
        if pinnedScreenIndex < screens.count {
            return screens[pinnedScreenIndex]
        }
        return NSScreen.main ?? screens[0]
    }

    func layoutPanel(expanded: Bool) {
        let screen = pinnedScreen
        let screenFrame = screen.frame
        let width = expanded ? expandedWidth : collapsedWidth
        let height = viewModel.targetHeight()

        let x: CGFloat
        switch dockedEdge {
        case .right:
            x = screenFrame.maxX - width
        case .left:
            x = screenFrame.minX
        case .floating:
            // Keep right edge fixed when expanding
            x = panel.frame.origin.x + panel.frame.width - width
        }

        // Clamp height to screen and shift up if panel would extend past the bottom
        let maxHeight = screenFrame.height - anchorY
        let clampedHeight = min(height, maxHeight)
        let y = screenFrame.maxY - anchorY - clampedHeight
        panel.setFrame(NSRect(x: x, y: y, width: width, height: clampedHeight), display: true)
    }

    // MARK: - Expand / Collapse

    func expand() {
        guard !viewModel.isExpanded, !transitioning, !isDragging else { return }
        transitioning = true
        collapseTimer?.invalidate()
        collapseTimer = nil

        viewModel.isExpanded = true
        viewModel.refreshStatuses()
        viewModel.startPolling()
        layoutPanel(expanded: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.transitioning = false
        }
    }

    func collapse() {
        guard viewModel.isExpanded, !transitioning, !isDragging else { return }
        transitioning = true
        collapseTimer?.invalidate()
        collapseTimer = nil

        viewModel.showingPortalPicker = false
        viewModel.isExpanded = false
        viewModel.stopPolling()
        layoutPanel(expanded: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.transitioning = false
        }
    }

    // MARK: - Mouse Tracking

    private func setupMouseTracking() {
        // Global events
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDragged, .leftMouseUp:
                self.handleDragEvent(event)
            default:
                self.handleMousePosition()
            }
        }

        // Local events (inside our panel)
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown:
                self.handleMouseDown(event)
            case .leftMouseDragged, .leftMouseUp:
                self.handleDragEvent(event)
            default:
                self.handleMousePosition()
            }
            return event
        }

        // Safety net poll using GCD timer
        let pollTimer = DispatchSource.makeTimerSource(queue: .main)
        pollTimer.schedule(deadline: .now() + 0.5, repeating: 0.2)
        pollTimer.setEventHandler { [weak self] in
            self?.handleMousePosition()
        }
        pollTimer.resume()
        self.pollTimerSource = pollTimer
    }

    /// Check if a screen-space point is in the draggable part of the titlebar.
    /// Excludes the right 100px where action buttons (cascade, settings, add) live.
    private func isInTitlebarDragArea(_ screenPoint: NSPoint) -> Bool {
        let panelFrame = panel.frame
        let buttonsWidth: CGFloat = 100
        let dragRect = NSRect(
            x: panelFrame.minX,
            y: panelFrame.maxY - titlebarHeight,
            width: panelFrame.width - buttonsWidth,
            height: titlebarHeight
        )
        return dragRect.contains(screenPoint)
    }

    private func handleMouseDown(_ event: NSEvent) {
        // Only allow drag from titlebar when expanded
        guard viewModel.isExpanded else { return }

        let screenPoint = NSEvent.mouseLocation
        guard isInTitlebarDragArea(screenPoint) else { return }

        isPendingDrag = true
        dragStartMouseLocation = screenPoint
        dragStartPanelOrigin = panel.frame.origin
    }

    private func handleDragEvent(_ event: NSEvent) {
        guard isPendingDrag || isDragging else { return }

        let currentMouse = NSEvent.mouseLocation

        if event.type == .leftMouseDragged {
            let dx = currentMouse.x - dragStartMouseLocation.x
            let dy = currentMouse.y - dragStartMouseLocation.y

            if isPendingDrag && !isDragging {
                let dist = sqrt(dx * dx + dy * dy)
                if dist >= dragThreshold {
                    isDragging = true
                    isPendingDrag = false
                    // Collapse to thin strip while dragging
                    viewModel.showingPortalPicker = false
                    viewModel.isExpanded = false
                    // Recalculate origin for collapsed size, keeping mouse relative position
                    let collapsedHeight = viewModel.targetHeight()
                    dragStartPanelOrigin = NSPoint(
                        x: currentMouse.x - collapsedWidth / 2,
                        y: currentMouse.y - collapsedHeight / 2
                    )
                    dragStartMouseLocation = currentMouse
                }
            }

            if isDragging {
                let ddx = currentMouse.x - dragStartMouseLocation.x
                let ddy = currentMouse.y - dragStartMouseLocation.y
                panel.setFrame(
                    NSRect(
                        x: dragStartPanelOrigin.x + ddx,
                        y: dragStartPanelOrigin.y + ddy,
                        width: collapsedWidth,
                        height: viewModel.targetHeight()
                    ),
                    display: true
                )
            }
        } else if event.type == .leftMouseUp {
            if isDragging {
                endDrag()
            }
            isPendingDrag = false
            isDragging = false
        }
    }

    private func endDrag() {
        let mouseLocation = NSEvent.mouseLocation
        // Pin to whichever screen the mouse is on
        let screens = NSScreen.screens
        pinnedScreenIndex = screens.firstIndex(where: { $0.frame.contains(mouseLocation) }) ?? 0
        let screen = pinnedScreen
        let screenFrame = screen.frame

        // Use mouse position (not panel frame) to decide edge snapping,
        // since the panel is a thin strip that may not reach the edge
        let distToRight = screenFrame.maxX - mouseLocation.x
        let distToLeft = mouseLocation.x - screenFrame.minX

        if distToRight < snapThreshold {
            dockedEdge = .right
        } else if distToLeft < snapThreshold {
            dockedEdge = .left
        } else {
            dockedEdge = .floating
        }

        let panelFrame = panel.frame
        anchorY = screenFrame.maxY - panelFrame.maxY
        layoutPanel(expanded: false)
        savePosition()
    }

    // MARK: - Hover expand/collapse

    private func handleMousePosition() {
        guard !transitioning, !isDragging, !isPendingDrag else { return }

        let mouseLocation = NSEvent.mouseLocation
        let panelFrame = panel.frame
        let inBounds = panelFrame.contains(mouseLocation)

        if inBounds {
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !viewModel.isExpanded {
                expand()
            }
        } else {
            if viewModel.isExpanded {
                if collapseTimer == nil {
                    collapseTimer = Timer.scheduledTimer(withTimeInterval: collapseDelayMs, repeats: false) { [weak self] _ in
                        self?.collapse()
                    }
                }
            }
        }
    }

    // MARK: - Add Project Dialog

    func showAddProjectDialog() {
        // Temporarily become a regular app so NSOpenPanel can appear
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        openPanel.directoryURL = homeDir.appendingPathComponent("dev")

        openPanel.begin { [weak self] response in
            if response == .OK, let url = openPanel.url {
                DispatchQueue.main.async {
                    self?.viewModel.addProject(path: url.path)
                }
            }
            // Revert to accessory app (no dock icon)
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
