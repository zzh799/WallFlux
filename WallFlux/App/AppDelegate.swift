import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core = CoreManager.shared
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        core.start()
        menuBarController = MenuBarController(core: core)
        // 首启弹窗稍后展示，避免与菜单栏图标出现抢焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showLaunchAtLoginPromptIfNeeded()
        }
        // E2E 调试入口：--open-settings 启动后直接打开设置窗口
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                SettingsWindowController.shared.show()
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.shutdown()
    }

    // MARK: - 首启弹窗（设计 §1.2）

    /// 首次启动弹窗询问开机自启（默认关闭，不静默开启）；
    /// 若电量偏低且智能暂停已触发，同时简述当前暂停状态，避免用户困惑。
    private func showLaunchAtLoginPromptIfNeeded() {
        guard !LaunchAtLogin.didShowPrompt else { return }
        LaunchAtLogin.didShowPrompt = true

        let alert = NSAlert()
        alert.messageText = "欢迎使用 WallFlux"
        alert.informativeText = "是否在登录时自动启动 WallFlux？"

        // 勾选项：开机自启（默认不勾选，由用户主动决定）
        let checkbox = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
        checkbox.state = .off

        // 智能暂停已触发时简述当前状态
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.addArrangedSubview(checkbox)
        let reasons = core.smartPauseMonitor.activeReasons
        if !reasons.isEmpty {
            let label = NSTextField(wrappingLabelWithString:
                "当前已暂停：\(reasons.map(\.displayName).joined(separator: "、"))，条件解除后自动恢复。")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            accessory.addArrangedSubview(label)
        }
        alert.accessoryView = accessory

        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "稍后再说")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn && checkbox.state == .on {
            LaunchAtLogin.enable()
        }
    }
}
