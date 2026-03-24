// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orch3-launcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "orch3-launcher",
            path: "Sources/Launcher",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        )
    ]
)
