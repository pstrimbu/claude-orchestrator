import Foundation

struct ProjectEntry: Codable, Identifiable, Equatable {
    var path: String
    var name: String
    var id: String { path }
}

struct ProjectsConfig: Codable {
    var projects: [ProjectEntry]
}

struct HiddenPortals: Codable {
    var hidden: [String]
}

struct PortalCsvEntry {
    var name: String
    var uiPort: UInt16
    var apiPort: UInt16
    var dir: String
    var startCmd: String
}

struct PortalEntryResponse: Identifiable {
    var name: String
    var uiPort: UInt16
    var apiPort: UInt16
    var path: String
    var visible: Bool
    var id: String { name }
}

struct AppStatus: Identifiable, Equatable {
    var name: String
    var sessionPath: String?
    var sessionRunning: Bool
    var sessionPid: Int32?
    var portalName: String?
    var uiPort: UInt16?
    var apiPort: UInt16?
    var portalPath: String?
    var portalStartCmd: String?
    var uiRunning: Bool
    var apiRunning: Bool
    var pathMissing: Bool = false

    var id: String { sessionPath ?? portalName ?? name }
}
