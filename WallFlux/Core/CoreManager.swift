import AppKit
import Combine
import Foundation
import os

/// 核心协调器：串联 IdleDetector / ScreenManager / ConfigStore / AssetStore
final class CoreManager: ObservableObject {
    static let shared = CoreManager()
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "CoreManager")

    let configStore = ConfigStore.shared
    let assetStore = AssetStore.shared
    let idleDetector = IdleDetector()
    lazy var screenManager = ScreenManager(configStore: configStore, assetStore: assetStore)

    /// 全局暂停开关（面板上的快速暂停/恢复）
    @Published var isPaused = false {
        didSet { screenManager.setPaused(isPaused) }
    }

    /// 鼠标最近一次事件所在显示器的 displayID（用于检测鼠标移入/移出）
    private var lastMouseDisplayID: String?
    /// 辅助功能权限订阅：无权限时禁止闲置置顶播放
    private var trustSubscription: AnyCancellable?

    private init() {}

    func start() {
        assetStore.start()

        idleDetector.onInput = { [weak self] kind in
            self?.handleInput(kind)
        }
        idleDetector.start()

        screenManager.start()

        // 辅助功能权限变化 → 启用/禁用闲置置顶播放。无权限时输入检测失效，
        // 若仍进入闲置会置顶播放且永远无法退出，用户将被锁死在壁纸窗口下。
        // @Published 订阅时立即发送当前值，启动初期未授权也能正确禁用。
        trustSubscription = idleDetector.$isTrusted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] trusted in
                self?.screenManager.setInputMonitoringEnabled(trusted)
            }
    }

    func shutdown() {
        trustSubscription?.cancel()
        trustSubscription = nil
        idleDetector.stop()
        screenManager.shutdown()
    }

    // MARK: - 私有

    private func handleInput(_ kind: IdleDetector.InputKind) {
        guard !isPaused else { return }
        switch kind {
        case .mouseMoved:
            // 纯移动（弱输入）：记录鼠标所在显示器变化，走短暂进入宽限机制
            handleMouseMoved()
        case .mouseClicked:
            // 点击 / 拖拽 / 滚动（强输入）：立即标记鼠标所在显示器活跃，不走宽限
            handleMouseClicked()
        case .keyPressed:
            // 键盘事件：优先标记焦点窗口所在显示器；AX 失败时逐级回退（鼠标位置 → 前台应用窗口），
            // 避免查询失败直接重置所有屏幕导致无输入屏幕无法进入闲置
            if let displayID = idleDetector.focusedDisplayID() {
                screenManager.markInput(displayID: displayID)
            } else if let mouseScreen = mouseLocationScreen() {
                logger.info("键盘输入 AX 失败，回退鼠标所在显示器 \(mouseScreen, privacy: .public)")
                screenManager.markInput(displayID: mouseScreen)
            } else if let frontScreen = idleDetector.frontmostWindowDisplayID() {
                logger.info("键盘输入回退前台应用窗口显示器 \(frontScreen, privacy: .public)")
                screenManager.markInput(displayID: frontScreen)
            } else {
                logger.info("键盘输入所有定位方式失败，回退全部显示器")
                screenManager.markInputAll()
            }
        }
    }

    /// 纯鼠标移动：鼠标移入新显示器时通知旧显示器移出；同一显示器内移动则刷新该显示器宽限状态
    private func handleMouseMoved() {
        guard let current = mouseLocationScreen() else { return }
        if current != lastMouseDisplayID {
            if let old = lastMouseDisplayID {
                screenManager.mouseLeft(displayID: old)
            }
            lastMouseDisplayID = current
        }
        screenManager.mouseMoved(displayID: current)
    }

    /// 点击 / 拖拽 / 滚动：强交互，立即退出闲置（不等待宽限期）
    private func handleMouseClicked() {
        guard let current = mouseLocationScreen() else { return }
        if current != lastMouseDisplayID {
            if let old = lastMouseDisplayID {
                screenManager.mouseLeft(displayID: old)
            }
            lastMouseDisplayID = current
        }
        screenManager.markInput(displayID: current)
    }

    /// 鼠标当前位置所在显示器的 displayID（无匹配时返回 nil）
    private func mouseLocationScreen() -> String? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        return String(screen.fluxDisplayID)
    }
}
