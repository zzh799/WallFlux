import AppKit
import SwiftUI

/// 设置窗口（单例，关闭即自动保存——所有修改即时写入 ConfigStore）
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "WallFlux 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if !window.isVisible {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
