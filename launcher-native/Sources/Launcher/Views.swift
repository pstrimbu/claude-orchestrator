import SwiftUI
import AppKit

// MARK: - Color Theme

extension Color {
    static let bg = Color(red: 30/255, green: 30/255, blue: 30/255)
    static let fg = Color(red: 204/255, green: 204/255, blue: 204/255)
    static let dim = Color(red: 128/255, green: 128/255, blue: 128/255)
    static let sep = Color(red: 51/255, green: 51/255, blue: 51/255)
    static let accent2 = Color(red: 95/255, green: 175/255, blue: 255/255)
    static let active = Color(red: 135/255, green: 215/255, blue: 135/255)
    static let error2 = Color(red: 255/255, green: 95/255, blue: 95/255)
    static let rowBg = Color(red: 37/255, green: 37/255, blue: 37/255)
    static let hoverBg = Color(red: 42/255, green: 42/255, blue: 42/255)
}

// MARK: - Root Content View

struct ContentView: View {
    @ObservedObject var viewModel: LauncherViewModel
    var onAddProject: () -> Void

    var body: some View {
        Group {
            if viewModel.isExpanded {
                ExpandedView(viewModel: viewModel, onAddProject: onAddProject)
            } else {
                CollapsedView(apps: viewModel.apps)
            }
        }
        .background(Color.bg)
    }
}

// MARK: - Collapsed View (dot strip)

struct CollapsedView: View {
    let apps: [AppStatus]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(apps) { app in
                let hasSession = app.sessionPath != nil
                let hasPortal = app.portalName != nil
                let portalRunning = app.uiRunning || app.apiRunning

                if hasSession && hasPortal {
                    HStack(spacing: 2) {
                        HalfDot(running: app.sessionRunning, isLeft: true)
                        HalfDot(running: portalRunning, isLeft: false)
                    }
                    .help(app.name)
                } else {
                    Circle()
                        .fill(dotColor(running: hasSession ? app.sessionRunning : portalRunning))
                        .frame(width: 10, height: 10)
                        .help(app.name)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    func dotColor(running: Bool) -> Color {
        running ? .active : Color(white: 0.27)
    }
}

struct HalfDot: View {
    let running: Bool
    let isLeft: Bool

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isLeft ? 5 : 0,
            bottomLeadingRadius: isLeft ? 5 : 0,
            bottomTrailingRadius: isLeft ? 0 : 5,
            topTrailingRadius: isLeft ? 0 : 5
        )
        .fill(running ? Color.active : Color(white: 0.27))
        .frame(width: 5, height: 10)
    }
}

// MARK: - Expanded View

struct ExpandedView: View {
    @ObservedObject var viewModel: LauncherViewModel
    var onAddProject: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar
            HStack {
                Text("orch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.dim)
                Spacer()
                HStack(spacing: 4) {
                    TitlebarButton(icon: "\u{21B6}", tooltip: "Undo", enabled: viewModel.canUndo) {
                        viewModel.undo()
                    }
                    TitlebarButton(icon: "\u{21B7}", tooltip: "Redo", enabled: viewModel.canRedo) {
                        viewModel.redo()
                    }
                    TitlebarButton(icon: "\u{25AE}", tooltip: "Cascade windows") {
                        viewModel.cascadeWindows()
                    }
                    TitlebarButton(icon: "\u{2699}", tooltip: "Show hidden portal") {
                        viewModel.showingProjectPicker = false
                        viewModel.showingPortalPicker = true
                    }
                    TitlebarButton(icon: "\u{21BB}", tooltip: "Reload config") {
                        viewModel.reloadProjects()
                    }
                    TitlebarButton(icon: "+", tooltip: "Add project") {
                        viewModel.showingPortalPicker = false
                        viewModel.showingProjectPicker.toggle()
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color.bg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.sep).frame(height: 1)
            }

            // App list or portal picker
            ScrollView {
                if viewModel.showingPortalPicker {
                    PortalPickerView(viewModel: viewModel)
                } else if viewModel.showingProjectPicker {
                    ProjectPickerView(viewModel: viewModel, onBrowse: onAddProject)
                } else if viewModel.apps.isEmpty {
                    Text("Click + to add a project")
                        .font(.system(size: 12))
                        .foregroundColor(.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 2) {
                        ForEach(viewModel.apps) { app in
                            ProjectRowView(app: app, viewModel: viewModel)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct TitlebarButton: View {
    let icon: String
    let tooltip: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled { action() } }) {
            Text(icon)
                .font(.system(size: 14))
                .foregroundColor(enabled ? .accent2 : .dim.opacity(0.35))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.sep, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(tooltip)
    }
}

// MARK: - Project Row

struct ProjectRowView: View {
    let app: AppStatus
    @ObservedObject var viewModel: LauncherViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            // Status dot + name
            HStack(spacing: 6) {
                statusDot
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(app.pathMissing ? .dim : .fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(app.pathMissing ? "Directory not found: \(app.sessionPath ?? app.portalPath ?? app.name)" : app.name)

            // Port badges
            if let uiPort = app.uiPort, let apiPort = app.apiPort {
                // UI badge: always opens browser
                UIPortBadge(port: uiPort, running: app.uiRunning)
                // API badge: toggles dev server start/stop
                APIPortBadge(port: apiPort, running: app.apiRunning, app: app, viewModel: viewModel)
            } else {
                Spacer().frame(width: 52)
                Spacer().frame(width: 52)
            }

            // Action buttons
            actionButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.hoverBg : Color.rowBg)
        )
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    var statusDot: some View {
        let hasSession = app.sessionPath != nil
        let portalRunning = app.uiRunning || app.apiRunning
        let running = hasSession ? app.sessionRunning : portalRunning
        Circle()
            .fill(app.pathMissing ? Color.dim.opacity(0.4) : (running ? Color.active : Color.error2))
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    var actionButtons: some View {
        let hasSession = app.sessionPath != nil
        let hasPortal = app.portalName != nil

        // Open/Focus
        if app.pathMissing {
            ActionButton(label: "Missing", style: .disabled) {}
        } else if hasSession {
            if app.sessionRunning, let pid = app.sessionPid {
                ActionButton(label: "Focus", style: .focus) {
                    viewModel.focusProject(pid: pid)
                }
            } else {
                ActionButton(label: "Open", style: .open) {
                    viewModel.openProject(path: app.sessionPath!)
                }
            }
        } else if hasPortal, let portalPath = app.portalPath {
            ActionButton(label: "Open", style: .open) {
                viewModel.openProject(path: portalPath)
            }
        } else {
            Spacer().frame(width: 52)
        }

        // Stop session
        if hasSession, app.sessionRunning, let pid = app.sessionPid {
            ActionButton(label: "Stop", style: .stop) {
                viewModel.stopProject(pid: pid)
            }
        } else {
            Spacer().frame(width: 52)
        }

        // Remove — always show (dimmed), brighten on row hover
        if hasSession {
            Button(action: { viewModel.removeProject(path: app.sessionPath!) }) {
                Text("\u{00D7}")
                    .font(.system(size: 14))
                    .foregroundColor(isHovered ? Color.dim.opacity(0.8) : Color.dim.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help("Remove \(app.name)")
        } else if hasPortal {
            Button(action: { viewModel.setPortalVisibility(name: app.portalName!, visible: false) }) {
                Text("\u{00D7}")
                    .font(.system(size: 14))
                    .foregroundColor(isHovered ? Color.dim.opacity(0.8) : Color.dim.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help("Hide \(app.name)")
        } else {
            Spacer().frame(width: 20)
        }
    }
}

// MARK: - Port Badges

/// UI port badge: always clickable, opens browser
struct UIPortBadge: View {
    let port: UInt16
    let running: Bool
    @State private var isHovered = false

    private var portString: String { "UI:\(port)" }

    var body: some View {
        Button(action: {
            NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
        }) {
            Text(isHovered ? "Open" : portString)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(running ? .active : .accent2)
                .frame(width: 52)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(running
                              ? Color.active.opacity(isHovered ? 0.3 : 0.15)
                              : Color.accent2.opacity(isHovered ? 0.2 : 0.1))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// API port badge: toggles dev server start/stop
struct APIPortBadge: View {
    let port: UInt16
    let running: Bool
    let app: AppStatus
    @ObservedObject var viewModel: LauncherViewModel
    @State private var isHovered = false

    private var portString: String { "API:\(port)" }

    private var isPending: Bool {
        viewModel.pendingPortals.contains(app.name)
    }

    var body: some View {
        Button(action: {
            guard !isPending else { return }
            if running {
                viewModel.stopPortal(name: app.name, uiPort: app.uiPort!, apiPort: app.apiPort!)
            } else if let path = app.portalPath, let cmd = app.portalStartCmd {
                viewModel.startPortal(name: app.name, path: path, startCmd: cmd)
            }
        }) {
            Group {
                if isPending {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 52, height: 14)
                } else {
                    Text(isHovered ? (running ? "Stop" : "Start") : portString)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(running ? (isHovered ? .error2 : .active) : .dim)
                        .frame(width: 52)
                        .padding(.vertical, 2)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isPending
                          ? Color.accent2.opacity(0.1)
                          : running
                              ? (isHovered ? Color.error2.opacity(0.15) : Color.active.opacity(0.15))
                              : Color.error2.opacity(isHovered ? 0.2 : 0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Action Button

enum ActionButtonStyle {
    case focus, open, stop, disabled
}

struct ActionButton: View {
    let label: String
    let style: ActionButtonStyle
    let action: () -> Void

    private var fgColor: Color {
        switch style {
        case .focus: return .accent2
        case .open: return .active
        case .stop: return .error2
        case .disabled: return .dim.opacity(0.4)
        }
    }

    private var borderColor: Color {
        switch style {
        case .focus: return .accent2.opacity(0.3)
        case .open: return .active.opacity(0.3)
        case .stop: return .error2.opacity(0.2)
        case .disabled: return .dim.opacity(0.2)
        }
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(fgColor)
                .frame(width: 52)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(borderColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(style == .disabled)
    }
}

// MARK: - Portal Picker

struct PortalPickerView: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        let entries = viewModel.getAllPortalEntries().filter { !$0.visible }

        if entries.isEmpty {
            Text("All portals visible")
                .font(.system(size: 12))
                .foregroundColor(.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .onAppear { viewModel.showingPortalPicker = false }
        } else {
            VStack(spacing: 2) {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.fg)
                        Spacer()
                        ActionButton(label: "Add", style: .open) {
                            viewModel.setPortalVisibility(name: entry.name, visible: true)
                            viewModel.showingPortalPicker = false
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.rowBg)
                    )
                    .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Project Picker (add unregistered ~/dev projects)

struct ProjectPickerView: View {
    @ObservedObject var viewModel: LauncherViewModel
    var onBrowse: () -> Void

    var body: some View {
        let entries = viewModel.getUnregisteredProjects()
        VStack(spacing: 2) {
            // Browse for an arbitrary folder (outside ~/dev)
            HStack {
                Text("Browse for folder\u{2026}")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.dim)
                Spacer()
                ActionButton(label: "Browse", style: .focus) {
                    viewModel.showingProjectPicker = false
                    onBrowse()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.rowBg)
            )
            .padding(.horizontal, 4)

            if entries.isEmpty {
                Text("All ~/dev projects added")
                    .font(.system(size: 12))
                    .foregroundColor(.dim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.fg)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        ActionButton(label: "Add", style: .open) {
                            viewModel.addProject(path: entry.path)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.rowBg)
                    )
                    .padding(.horizontal, 4)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
