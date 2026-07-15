import Foundation
import Combine
import AppKit

final class LauncherViewModel: ObservableObject {
    @Published var apps: [AppStatus] = []
    @Published var projects: [ProjectEntry] = []
    @Published var isExpanded = false
    @Published var showingPortalPicker = false
    @Published var showingProjectPicker = false
    @Published var pendingPortals: Set<String> = []  // portal names currently starting/stopping
    @Published var canUndo = false
    @Published var canRedo = false
    private var removedNames: Set<String> = []  // recently removed — suppress from poll results

    private var pollTimer: Timer?

    // MARK: - Undo/Redo

    struct LauncherSnapshot {
        var projects: [ProjectEntry]
        var hiddenPortals: [String]
    }
    private var undoStack: [LauncherSnapshot] = []
    private var redoStack: [LauncherSnapshot] = []
    private let maxUndo = 50

    private func currentSnapshot() -> LauncherSnapshot {
        LauncherSnapshot(projects: projects, hiddenPortals: ConfigStore.loadHiddenPortals().hidden)
    }

    /// Capture the current state onto the undo stack before a mutating action.
    private func recordUndo() {
        undoStack.append(currentSnapshot())
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoRedoFlags()
    }

    private func updateUndoRedoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func applySnapshot(_ snap: LauncherSnapshot) {
        removedNames.removeAll()
        projects = snap.projects
        ConfigStore.saveProjects(projects)
        ConfigStore.saveHiddenPortals(HiddenPortals(hidden: snap.hiddenPortals))
        refreshStatuses()
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(snap)
        updateUndoRedoFlags()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(snap)
        updateUndoRedoFlags()
    }

    init() {
        projects = ConfigStore.loadProjects()
        refreshStatuses()
        listenForReloadNotification()
    }

    private func listenForReloadNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let vm = Unmanaged<LauncherViewModel>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async {
                vm.reloadProjects()
            }
        }, "com.orch.reload-projects" as CFString, nil, .deliverImmediately)
    }

    func reloadProjects() {
        removedNames.removeAll()
        // Config changed on disk out from under us — undo history no longer applies.
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoRedoFlags()
        projects = ConfigStore.loadProjects()
        refreshStatuses()
    }

    func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refreshStatuses() {
        let snapshot = projects
        let removed = removedNames
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statuses = Self.buildAppStatuses(projects: snapshot)
                .filter { !removed.contains($0.name) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = statuses
            }
        }
    }

    // MARK: - Project Actions

    func addProject(path: String) {
        let name = (path as NSString).lastPathComponent
        guard !projects.contains(where: { $0.path == path }) else { return }
        recordUndo()
        projects.append(ProjectEntry(path: path, name: name))
        // If this project was previously removed, un-suppress it and un-hide its
        // matching portal so it reappears fully.
        removedNames.remove(name)
        var cfg = ConfigStore.loadHiddenPortals()
        if let idx = cfg.hidden.firstIndex(of: name) {
            cfg.hidden.remove(at: idx)
            ConfigStore.saveHiddenPortals(cfg)
        }
        ConfigStore.saveProjects(projects)
        refreshStatuses()
    }

    func removeProject(path: String) {
        guard projects.contains(where: { $0.path == path }) else { return }
        recordUndo()
        let name = (path as NSString).lastPathComponent
        removedNames.insert(name)
        projects.removeAll { $0.path == path }
        apps.removeAll { $0.sessionPath == path || ($0.sessionPath == nil && $0.portalName == name) }
        ConfigStore.saveProjects(projects)
        // Also hide matching portal so it doesn't reappear as standalone.
        // Done synchronously so a fast undo can't race the async write.
        var cfg = ConfigStore.loadHiddenPortals()
        if !cfg.hidden.contains(name) {
            cfg.hidden.append(name)
            ConfigStore.saveHiddenPortals(cfg)
        }
    }

    /// Directories under ~/dev that aren't already registered as projects.
    func getUnregisteredProjects() -> [ProjectEntry] {
        let dev = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev").path
        let existing = Set(projects.map { $0.path })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dev) else { return [] }
        var result: [ProjectEntry] = []
        for name in names {
            if name.hasPrefix(".") { continue }
            let full = "\(dev)/\(name)"
            guard SystemUtils.directoryExists(full), !existing.contains(full) else { continue }
            result.append(ProjectEntry(path: full, name: name))
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func openProject(path: String) {
        // Add if not present
        if !projects.contains(where: { $0.path == path }) {
            addProject(path: path)
        }
        let orch = SystemUtils.orchExecutable()
        SystemUtils.shellBackground("'\(orch)' '\(path)' --continue", currentDir: path)
    }

    func focusProject(pid: Int32) {
        kill(pid, SIGUSR1)
    }

    func stopProject(pid: Int32) {
        kill(pid, SIGTERM)
    }

    func moveProject(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        ConfigStore.saveProjects(projects)
    }

    func reorderProjects(paths: [String]) {
        let byPath = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
        projects = paths.compactMap { byPath[$0] }
        ConfigStore.saveProjects(projects)
    }

    // MARK: - Portal Actions

    func startPortal(name: String, path: String, startCmd: String) {
        pendingPortals.insert(name)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", startCmd]
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()

            // Wait a moment for ports to start listening, then refresh
            Thread.sleep(forTimeInterval: 2.0)
            DispatchQueue.main.async {
                self?.pendingPortals.remove(name)
                self?.refreshStatuses()
            }
        }
    }

    func stopPortal(name: String, uiPort: UInt16, apiPort: UInt16) {
        pendingPortals.insert(name)
        SystemUtils.killPortListeners(port: uiPort)
        SystemUtils.killPortListeners(port: apiPort)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.pendingPortals.remove(name)
            self?.refreshStatuses()
        }
    }

    func setPortalVisibility(name: String, visible: Bool) {
        recordUndo()
        var cfg = ConfigStore.loadHiddenPortals()
        if visible {
            cfg.hidden.removeAll { $0 == name }
        } else if !cfg.hidden.contains(name) {
            cfg.hidden.append(name)
        }
        ConfigStore.saveHiddenPortals(cfg)
        refreshStatuses()
    }

    func getAllPortalEntries() -> [PortalEntryResponse] {
        let csv = ConfigStore.loadPortsCsv()
        let cfg = ConfigStore.loadHiddenPortals()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return csv.map { p in
            PortalEntryResponse(
                name: p.name,
                uiPort: p.uiPort,
                apiPort: p.apiPort,
                path: "\(home)/dev/\(p.dir)",
                visible: !cfg.hidden.contains(p.name)
            )
        }
    }

    // MARK: - Cascade

    func cascadeWindows() {
        let running = projects.compactMap { p -> (String, String, Int32)? in
            guard let pid = SystemUtils.getRunningPid(projectPath: p.path) else { return nil }
            return (p.name, p.path, pid)
        }.sorted(by: { $0.0 < $1.0 })

        guard !running.isEmpty else { return }

        // Group windows by the screen they're currently on
        var screenGroups: [String: [(String, String, Int32, NSScreen)]] = [:]
        for (name, path, pid) in running {
            let screen: NSScreen
            if let bounds = SystemUtils.getWindowBounds(pid: pid),
               let s = SystemUtils.screenForCGRect(bounds) {
                screen = s
            } else {
                screen = NSScreen.main ?? NSScreen.screens[0]
            }
            let key = "\(screen.frame.origin.x),\(screen.frame.origin.y)"
            screenGroups[key, default: []].append((name, path, pid, screen))
        }

        var firstPid: Int32?

        for (_, group) in screenGroups {
            guard let screen = group.first?.3 else { continue }

            let screenW = Int(screen.frame.width)
            let screenH = Int(screen.frame.height)
            // Convert screen origin to CG coordinates (top-left) for window-cmd
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let screenTopY = Int(primaryHeight - screen.frame.maxY)
            let menuBar = 25
            let workH = screenH - menuBar

            let maxOffset = 80
            let winW = 1200
            let winH = 800

            let baseX = Int(screen.frame.origin.x) + (screenW - winW) / 2
            let baseY = screenTopY + menuBar + workH - winH

            let availableY = baseY - (screenTopY + menuBar)
            let gaps = group.count - 1
            let offset = gaps > 0 ? min(maxOffset, availableY / gaps) : 0

            for i in stride(from: group.count - 1, through: 0, by: -1) {
                let (_, path, pid, _) = group[i]
                let x = baseX + offset * i
                let y = baseY - offset * i
                let orchDir = (path as NSString).appendingPathComponent(".orch")
                try? FileManager.default.createDirectory(atPath: orchDir, withIntermediateDirectories: true)
                let cmd: [String: Any] = ["x": x, "y": y, "focus": i == 0]
                if let data = try? JSONSerialization.data(withJSONObject: cmd) {
                    try? data.write(to: URL(fileURLWithPath: orchDir + "/window-cmd.json"))
                }
                kill(pid, SIGUSR2)
            }

            if firstPid == nil {
                firstPid = group.first?.2
            }
        }

        if let pid = firstPid {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                kill(pid, SIGUSR1)
            }
        }
    }

    // MARK: - Status Building

    static func buildAppStatuses(projects: [ProjectEntry]) -> [AppStatus] {
        let listening = SystemUtils.getListeningPorts()
        let csvPortals = ConfigStore.loadPortsCsv()
        let portalCfg = ConfigStore.loadHiddenPortals()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        struct PortalInfo {
            var name: String
            var uiPort: UInt16
            var apiPort: UInt16
            var path: String
            var startCmd: String
            var uiRunning: Bool
            var apiRunning: Bool
        }

        let visiblePortals: [PortalInfo] = csvPortals
            .filter { !portalCfg.hidden.contains($0.name) }
            .map { p in
                let path = "\(home)/dev/\(p.dir)"
                return PortalInfo(
                    name: p.name,
                    uiPort: p.uiPort,
                    apiPort: p.apiPort,
                    path: path,
                    startCmd: p.startCmd,
                    uiRunning: listening.contains(p.uiPort),
                    apiRunning: listening.contains(p.apiPort)
                )
            }

        var portalByDir: [String: Int] = [:]
        for (i, p) in visiblePortals.enumerated() {
            let dir = (p.path as NSString).lastPathComponent
            portalByDir[dir] = i
        }

        var usedPortals = Set<String>()
        var apps: [AppStatus] = []

        for proj in projects {
            let pid = SystemUtils.getRunningPid(projectPath: proj.path)
            let portal = portalByDir[proj.name].map { visiblePortals[$0] }
            if portal != nil {
                usedPortals.insert(proj.name)
            }

            apps.append(AppStatus(
                name: proj.name,
                sessionPath: proj.path,
                sessionRunning: pid != nil,
                sessionPid: pid,
                portalName: portal?.name,
                uiPort: portal?.uiPort,
                apiPort: portal?.apiPort,
                portalPath: portal?.path,
                portalStartCmd: portal?.startCmd,
                uiRunning: portal?.uiRunning ?? false,
                apiRunning: portal?.apiRunning ?? false,
                pathMissing: !SystemUtils.directoryExists(proj.path)
            ))
        }

        for p in visiblePortals {
            let dir = (p.path as NSString).lastPathComponent
            if !usedPortals.contains(dir) {
                apps.append(AppStatus(
                    name: p.name,
                    sessionPath: nil,
                    sessionRunning: false,
                    sessionPid: nil,
                    portalName: p.name,
                    uiPort: p.uiPort,
                    apiPort: p.apiPort,
                    portalPath: p.path,
                    portalStartCmd: p.startCmd,
                    uiRunning: p.uiRunning,
                    apiRunning: p.apiRunning,
                    pathMissing: !SystemUtils.directoryExists(p.path)
                ))
            }
        }

        apps.sort { $0.name.lowercased() < $1.name.lowercased() }
        return apps
    }

    // MARK: - Height Calculation

    func targetHeight() -> CGFloat {
        let itemHeight: CGFloat = isExpanded ? 32 : 16
        let chrome: CGFloat = isExpanded ? 50 : 16
        return min(800, max(60, chrome + CGFloat(apps.count) * itemHeight))
    }
}
