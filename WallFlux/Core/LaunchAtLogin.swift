import AppKit
import Foundation
import ServiceManagement

/// 开机自启（设计文档 §1）
///
/// 使用 `SMAppService.mainApp`（macOS 13+ 原生 API），真相源 = 系统状态，
/// 不在 `AppConfig` 里冗余存布尔，避免与系统状态失同步。
/// 开关位置：菜单栏面板 + 全局设置「启动」分区，双向同步；
/// 视图 onAppear 时读取真实状态刷新，不做定时轮询。
enum LaunchAtLogin {
    /// 首启询问弹窗标记（UserDefaults，设计 §1.2）
    static let didShowPromptKey = "WallFlux.didShowLaunchAtLoginPrompt"

    /// 系统当前状态
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// 开关显示状态：已启用或已注册待批准均视为「开」
    static var isEnabled: Bool {
        switch status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
        }
    }

    /// 是否处于「已注册但系统未批准」状态（需引导用户去系统设置批准）
    static var requiresApproval: Bool {
        status == .requiresApproval
    }

    /// 开启：注册为主应用登录项
    @discardableResult
    static func enable() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            NSLog("WallFlux 开机自启注册失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 关闭：注销登录项
    @discardableResult
    static func disable() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            NSLog("WallFlux 开机自启注销失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 是否已弹过首启询问
    static var didShowPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: didShowPromptKey) }
        set { UserDefaults.standard.set(newValue, forKey: didShowPromptKey) }
    }

    /// 打开「登录项与扩展」系统设置（.requiresApproval 状态引导用）
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
