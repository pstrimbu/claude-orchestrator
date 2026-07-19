import Foundation
import Combine
import AppKit

final class LauncherViewModel: ObservableObject {
    @Published var apps: [AppStatus] = []
    @Published var projects: [ProjectEntry] = []
    @Published var pinned: Set<String> = ConfigStore.loadPinned()
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
        let pins = pinned
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statuses = Self.buildAppStatuses(projects: snapshot, pinned: pins)
                .filter { !removed.contains($0.name) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = statuses
            }
        }
    }

    /// Pin/unpin a project. Pinned entries sort to the top of the list and are
    /// grouped onto the primary display's right half when organizing windows.
    func togglePin(name: String) {
        if pinned.contains(name) { pinned.remove(name) } else { pinned.insert(name) }
        ConfigStore.savePinned(pinned)
        refreshStatuses()
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

        let pins = pinned
        let pinnedWins = running.filter { pins.contains($0.0) }
        let otherWins = running.filter { !pins.contains($0.0) }

        // Identify the primary (menu-bar) display and, if present, a secondary.
        let screens = NSScreen.screens
        let primary = screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main ?? screens.first
        guard let primary = primary else { return }
        let secondary = screens
            .filter { $0 != primary }
            .sorted { $0.frame.minX < $1.frame.minX }
            .first

        // Half-screen regions (AppKit coords, origin bottom-left).
        func leftHalf(_ s: NSScreen) -> NSRect {
            let v = s.visibleFrame
            return NSRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        }
        func rightHalf(_ s: NSScreen) -> NSRect {
            let v = s.visibleFrame
            return NSRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        }

        // Placement policy:
        //  - Pinned windows share one stack on the primary display's RIGHT half
        //    (the left half of the primary is reserved for a browser).
        //  - Everything else fills, in order: secondary-left, secondary-right, then
        //    the primary's left half only as overflow.
        var frontToBack: [Int32] = []

        if !pinnedWins.isEmpty {
            placeCascade(group: pinnedWins, in: rightHalf(primary), frontToBack: &frontToBack)
        }

        if !otherWins.isEmpty {
            var zones: [NSRect]
            if let sec = secondary {
                zones = [leftHalf(sec), rightHalf(sec)]
                // Spill onto the primary's (reserved) left half only when the two
                // secondary halves would be overcrowded.
                let softCap = 6
                if otherWins.count > zones.count * softCap { zones.append(leftHalf(primary)) }
            } else {
                zones = [leftHalf(primary)]
            }

            // Distribute the others evenly across the chosen zones (balanced,
            // contiguous chunks; earlier zones absorb the remainder).
            let per = otherWins.count / zones.count
            let rem = otherWins.count % zones.count
            var idx = 0
            for (zi, zone) in zones.enumerated() {
                let cnt = per + (zi < rem ? 1 : 0)
                guard cnt > 0 else { continue }
                placeCascade(group: Array(otherWins[idx ..< idx + cnt]), in: zone, frontToBack: &frontToBack)
                idx += cnt
            }
        }

        // Each orch window is its own app, so cross-app stacking follows activation
        // order. Raise back-to-front with a small stagger so the bottom-left window
        // of each stack ends up in front and the rising staircase of status bars is
        // revealed. (The SIGUSR2 handler applies the frame and focuses the window.)
        let raiseOrder = Array(frontToBack.reversed())
        for (k, pid) in raiseOrder.enumerated() {
            let delay = Double(k) * 0.04
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { kill(pid, SIGUSR2) }
        }
        if let front = frontToBack.first {
            let settle = Double(raiseOrder.count) * 0.04 + 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { kill(front, SIGUSR1) }
        }
    }

    /// Cascade one stack of windows within `region` (AppKit coordinates: origin
    /// bottom-left, y up). The front window sits at the bottom-left and each
    /// subsequent window steps up and to the right, so every window's top status
    /// bar clears the window in front of it. Windows are hard-clamped inside the
    /// region so none can ever land off-screen.
    private func placeCascade(group: [(String, String, Int32)], in region: NSRect,
                              frontToBack: inout [Int32]) {
        let margin: CGFloat = 8
        let maxStepX: CGFloat = 48
        let maxStepY: CGFloat = 64   // clear the ~28px status bar + title bar

        let winW = min(CGFloat(1200), region.width - margin * 2)
        let winH = min(CGFloat(864), region.height - margin * 2)

        let gaps = CGFloat(max(0, group.count - 1))
        let stepX = gaps > 0 ? max(0, min(maxStepX, (region.width  - winW - margin * 2) / gaps)) : 0
        let stepY = gaps > 0 ? max(0, min(maxStepY, (region.height - winH - margin * 2) / gaps)) : 0

        // i == 0: front window at the bottom-left. Increasing i steps up-and-right.
        let startX = region.minX + margin
        let startY = region.minY + margin   // NS bottom edge of the front window

        for i in 0 ..< group.count {
            let (_, path, pid) = group[i]
            let x = min(max(startX + stepX * CGFloat(i), region.minX), region.maxX - winW)
            let y = min(max(startY + stepY * CGFloat(i), region.minY), region.maxY - winH)
            let orchDir = (path as NSString).appendingPathComponent(".orch")
            try? FileManager.default.createDirectory(atPath: orchDir, withIntermediateDirectories: true)
            // focus: true for every window — the staggered back-to-front raise in
            // cascadeWindows() is what establishes the final z-order.
            let cmd: [String: Any] = ["x": Int(x), "y": Int(y), "w": Int(winW), "h": Int(winH), "focus": true]
            if let data = try? JSONSerialization.data(withJSONObject: cmd) {
                try? data.write(to: URL(fileURLWithPath: orchDir + "/window-cmd.json"))
            }
            frontToBack.append(pid)   // i == 0 (front) appended first
        }
    }

    // MARK: - Status Building

    static func buildAppStatuses(projects: [ProjectEntry], pinned: Set<String> = []) -> [AppStatus] {
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
                pathMissing: !SystemUtils.directoryExists(proj.path),
                pinned: pinned.contains(proj.name)
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
                    pathMissing: !SystemUtils.directoryExists(p.path),
                    pinned: pinned.contains(p.name)
                ))
            }
        }

        // Pinned entries float to the top; alphabetical within each group.
        apps.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.name.lowercased() < b.name.lowercased()
        }
        return apps
    }

    // MARK: - Height Calculation

    func targetHeight() -> CGFloat {
        let itemHeight: CGFloat = isExpanded ? 32 : 16
        let chrome: CGFloat = isExpanded ? 50 : 16
        return min(800, max(60, chrome + CGFloat(apps.count) * itemHeight))
    }
}
