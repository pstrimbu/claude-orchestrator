// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "orch-launcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "orch-launcher",
            path: "Sources/Launcher",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        )
    ]
)
