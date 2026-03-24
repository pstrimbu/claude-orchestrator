import AppKit
import Foundation

// Single instance check via file lock
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/orch/launcher.lock").path

let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o644)
if lockFd >= 0 {
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    lock.l_start = 0
    lock.l_len = 0
    if fcntl(lockFd, F_SETLK, &lock) == -1 {
        // Another instance is running
        // Try to bring it to front via distributed notification
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.orch.launcher.activate"),
            object: nil
        )
        exit(0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panelController: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force dark mode
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        let viewModel = LauncherViewModel()
        panelController = PanelController(viewModel: viewModel)

        // Listen for activate notification from other instances
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.orch.launcher.activate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.panelController.panel.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
