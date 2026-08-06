import AppKit
import Combine
import Foundation

/// 核心协调器：串联 IdleDetector / ScreenManager / ConfigStore / AssetStore
final class CoreManager: ObservableObject {
    static let shared = CoreManager()

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
            // 键盘事件：标记焦点窗口所在显示器为活跃；查询失败时回退为所有显示器（保守防烧屏）
            if let displayID = idleDetector.focusedDisplayID() {
                screenManager.markInput(displayID: displayID)
            } else {
                screenManager.markInputAll()
            }
        }
    }
}
