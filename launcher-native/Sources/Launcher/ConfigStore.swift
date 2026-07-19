import Foundation

enum ConfigStore {
    static let homeDir = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = homeDir.appendingPathComponent(".config/orch")
    static let projectsFile = configDir.appendingPathComponent("launcher-projects.json")
    static let portalsFile = configDir.appendingPathComponent("launcher-portals.json")
    static let pinsFile = configDir.appendingPathComponent("launcher-pins.json")
    static let portsCsvPath = homeDir.appendingPathComponent("dev/dev-application-ports.csv")

    static func loadProjects() -> [ProjectEntry] {
        guard let data = try? Data(contentsOf: projectsFile),
              let config = try? JSONDecoder().decode(ProjectsConfig.self, from: data) else {
            return []
        }
        return config.projects
    }

    static func saveProjects(_ projects: [ProjectEntry]) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let config = ProjectsConfig(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: projectsFile)
        }
    }

    static func loadHiddenPortals() -> HiddenPortals {
        guard let data = try? Data(contentsOf: portalsFile),
              let config = try? JSONDecoder().decode(HiddenPortals.self, from: data) else {
            return HiddenPortals(hidden: [])
        }
        return config
    }

    static func saveHiddenPortals(_ config: HiddenPortals) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: portalsFile)
        }
    }

    static func loadPinned() -> Set<String> {
        guard let data = try? Data(contentsOf: pinsFile),
              let config = try? JSONDecoder().decode(PinnedProjects.self, from: data) else {
            return []
        }
        return Set(config.pinned)
    }

    static func savePinned(_ names: Set<String>) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(PinnedProjects(pinned: Array(names).sorted())) {
            try? data.write(to: pinsFile)
        }
    }

    static func loadPortsCsv() -> [PortalCsvEntry] {
        guard let content = try? String(contentsOf: portsCsvPath, encoding: .utf8) else {
            return []
        }
        var result: [PortalCsvEntry] = []
        for line in content.components(separatedBy: .newlines).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: ",")
            guard parts.count >= 3 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard let uiPort = UInt16(parts[1].trimmingCharacters(in: .whitespaces)),
                  let apiPort = UInt16(parts[2].trimmingCharacters(in: .whitespaces)),
                  uiPort > 0, apiPort > 0 else { continue }
            let dir = parts.count > 6
                ? parts[6].trimmingCharacters(in: .whitespaces)
                : name
            let startCmd = parts.count > 7
                ? parts[7].trimmingCharacters(in: .whitespaces)
                : "npm run dev"
            result.append(PortalCsvEntry(name: name, uiPort: uiPort, apiPort: apiPort, dir: dir, startCmd: startCmd))
        }
        return result
    }
}
