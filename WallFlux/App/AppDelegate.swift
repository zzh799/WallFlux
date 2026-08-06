import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = CoreManager.shared
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        core.start()
        menuBarController = MenuBarController(core: core)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.shutdown()
    }
}
