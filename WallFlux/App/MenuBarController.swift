import AppKit
import SwiftUI

/// 菜单栏状态项与控制面板（静态图标，点击 toggle 弹出）
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let core: CoreManager
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(core: CoreManager) {
        self.core = core
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "WallFlux")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let hosting = NSHostingController(rootView: MenuBarPanelView(core: core))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 320, height: 500)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - NSPopoverDelegate

    /// 面板每次打开前：刷新辅助功能权限（授权后打开面板立即生效，无需等轮询或点击面板）
    /// 并递增 panelSessionID，让面板内的会话级快照（最近使用排序）以最新记录重建
    func popoverWillShow(_ notification: Notification) {
        core.panelWillOpen()
    }
}
