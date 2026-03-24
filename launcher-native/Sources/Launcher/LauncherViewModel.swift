import Foundation
import Combine
import AppKit

final class LauncherViewModel: ObservableObject {
    @Published var apps: [AppStatus] = []
    @Published var projects: [ProjectEntry] = []
    @Published var isExpanded = false
    @Published var showingPortalPicker = false
    @Published var pendingPortals: Set<String> = []  // portal names currently starting/stopping

    private var pollTimer: Timer?

    init() {
        projects = ConfigStore.loadProjects()
        refreshStatuses()
        startPolling()
    }

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatuses()
        }
    }

    func refreshStatuses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let projects = self.projects
            let statuses = Self.buildAppStatuses(projects: projects)
            DispatchQueue.main.async {
                self.apps = statuses
            }
        }
    }

    // MARK: - Project Actions

    func addProject(path: String) {
        let name = (path as NSString).lastPathComponent
        guard !projects.contains(where: { $0.path == path }) else { return }
        projects.append(ProjectEntry(path: path, name: name))
        ConfigStore.saveProjects(projects)
        refreshStatuses()
    }

    func removeProject(path: String) {
        projects.removeAll { $0.path == path }
        ConfigStore.saveProjects(projects)
        refreshStatuses()
    }

    func openProject(path: String) {
        // Add if not present
        if !projects.contains(where: { $0.path == path }) {
            addProject(path: path)
        }
        SystemUtils.shellBackground("orch3 '\(path)' --continue", currentDir: path)
    }

    func focusProject(pid: Int32) {
        kill(pid, SIGUSR1)
    }

    func stopProject(pid: Int32) {
        kill(pid, SIGTERM)
    }

    func moveProject(from source: IndexSet, to destination: Int) {
        // Only move projects that have sessionPaths (not standalone portals)
        var projectPaths = projects.map(\.path)
        // This is a simplified reorder - works on the projects list directly
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
        guard let screen = NSScreen.main else { return }

        let screenW = Int(screen.frame.width)
        let screenH = Int(screen.frame.height)
        let menuBar = 25
        let workH = screenH - menuBar

        let maxOffset = 80
        let winW = 1200
        let winH = 800

        let baseX = (screenW - winW) / 2
        let baseY = menuBar + workH - winH

        let availableY = baseY - menuBar
        let gaps = running.count - 1
        let offset = gaps > 0 ? min(maxOffset, availableY / gaps) : 0

        for i in stride(from: running.count - 1, through: 0, by: -1) {
            let (_, path, pid) = running[i]
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

        if let (_, _, pid) = running.first {
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
                apiRunning: portal?.apiRunning ?? false
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
                    apiRunning: p.apiRunning
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
