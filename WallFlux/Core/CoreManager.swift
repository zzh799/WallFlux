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

    private init() {}

    func start() {
        assetStore.start()

        idleDetector.onInput = { [weak self] kind in
            self?.handleInput(kind)
        }
        idleDetector.start()

        screenManager.start()
    }

    func shutdown() {
        idleDetector.stop()
        screenManager.shutdown()
    }

    // MARK: - 私有

    private func handleInput(_ kind: IdleDetector.InputKind) {
        guard !isPaused else { return }
        switch kind {
        case .mouseMoved:
            // 鼠标事件：仅标记鼠标所在显示器为活跃
            let point = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                screenManager.markInput(displayID: String(screen.fluxDisplayID))
            }
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

    /// 鼠标当前位置所在显示器的 displayID（无匹配时返回 nil）
    private func mouseLocationScreen() -> String? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return nil }
        return String(screen.fluxDisplayID)
    }
}
