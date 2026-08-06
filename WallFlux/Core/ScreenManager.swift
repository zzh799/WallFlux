import AppKit
import Combine
import Foundation
import os

/// NSScreen 显示器唯一标识（CGDirectDisplayID）
/// macOS 15 SDK 移除了 screenNumber，统一从 deviceDescription 的 NSScreenNumber 取值，
/// 该 key 在所有受支持版本（macOS 14+）均稳定可用。
extension NSScreen {
    var fluxDisplayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return 0 }
        return CGDirectDisplayID(number.uint32Value)
    }
}

/// 显示器管理：枚举显示器、处理热插拔、维护 ScreenContext 生命周期
final class ScreenManager: ObservableObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "ScreenManager")
    @Published private(set) var contexts: [ScreenContext] = []

    private let configStore: ConfigStore
    private let assetStore: AssetStore
    private let engine = WallpaperEngine()
    private var observers: [NSObjectProtocol] = []
    private var isPaused = false

    init(configStore: ConfigStore, assetStore: AssetStore) {
        self.configStore = configStore
        self.assetStore = assetStore
    }

    func start() {
        // 热插拔 / 分辨率变化监听
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildContexts()
        })

        // 配置变更 → 刷新各显示器壁纸
        configStore.onChange = { [weak self] in
            self?.reloadAllWallpapers()
        }

        // 素材增删 → 刷新各显示器壁纸
        assetStore.onChange = { [weak self] in
            self?.reloadAllWallpapers()
        }

        rebuildContexts()
        logger.info("已创建 \(self.contexts.count) 个显示器上下文")
    }

    func shutdown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        contexts.forEach { $0.shutdown() }
        contexts.removeAll()
    }

    /// 鼠标输入：标记鼠标所在显示器活跃（强输入：点击/拖拽/滚动/键盘）
    func markInput(displayID: String) {
        contexts.first { $0.displayID == displayID }?.inputDetected()
    }

    /// 纯鼠标移动（弱输入）：刷新该显示器的短暂进入宽限状态
    func mouseMoved(displayID: String) {
        contexts.first { $0.displayID == displayID }?.mouseMoved()
    }

    /// 鼠标移出该显示器：取消其短暂进入宽限，保持播放
    func mouseLeft(displayID: String) {
        contexts.first { $0.displayID == displayID }?.mouseLeft()
    }

    /// 键盘输入：所有显示器活跃
    func markInputAll() {
        contexts.forEach { $0.inputDetected() }
    }

    /// 全局暂停 / 恢复
    func setPaused(_ paused: Bool) {
        isPaused = paused
        contexts.forEach { paused ? $0.pauseGlobally() : $0.resumeGlobally() }
    }

    func context(for displayID: String) -> ScreenContext? {
        contexts.first { $0.displayID == displayID }
    }

    func reloadAllWallpapers() {
        contexts.forEach { $0.reloadWallpaperIfNeeded() }
    }

    // MARK: - 私有

    /// 按当前 NSScreen 列表重建上下文集合（保留未变动的上下文状态）
    private func rebuildContexts() {
        let screens = NSScreen.screens
        let screenIDs = Set(screens.map { String($0.fluxDisplayID) })

        // 移除已断开显示器的上下文
        contexts.removeAll { ctx in
            guard !screenIDs.contains(ctx.displayID) else { return false }
            ctx.shutdown()
            return true
        }

        // 已存在但屏幕对象可能更新的显示器：同步窗口位置
        for ctx in contexts {
            if let screen = screens.first(where: { String($0.fluxDisplayID) == ctx.displayID }) {
                ctx.updateScreen(screen)
            }
        }

        // 为新增显示器创建上下文
        let existingIDs = Set(contexts.map { $0.displayID })
        for screen in screens {
            let id = String(screen.fluxDisplayID)
            guard !existingIDs.contains(id) else { continue }
            let ctx = ScreenContext(screen: screen, displayID: id,
                                    configStore: configStore, assetStore: assetStore, engine: engine)
            contexts.append(ctx)
            ctx.start()
            if isPaused {
                ctx.pauseGlobally()
            }
        }
    }
}
