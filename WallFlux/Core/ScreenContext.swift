import AppKit
import Combine
import Foundation
import os

/// 单个显示器的运行时上下文
///
/// 状态机（见技术文档 §4）：
/// active（微跳）→ idle（循环播放）→ exiting（退出动画）→ active
final class ScreenContext: ObservableObject, Identifiable {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "ScreenContext")
    @Published private(set) var state: DisplayState = .active
    @Published private(set) var displayConfig: DisplayConfig

    let displayID: String
    private(set) var screen: NSScreen

    var id: String { displayID }

    /// 当前生效的壁纸名称（含回退逻辑）
    var wallpaperName: String {
        resolveAsset()?.name ?? "未设置"
    }

    private let configStore: ConfigStore
    private let assetStore: AssetStore
    private weak var engine: WallpaperEngine?

    private var idleTimer: Timer?
    private var microStepTimer: Timer?
    /// 短暂进入宽限计时器（固定时长，不随移动刷新）：持续移动满宽限期才退出闲置
    private var graceTimer: Timer?
    /// 鼠标停止看门狗（随每次移动刷新）：超过阈值无移动则视为鼠标停止，取消宽限保持播放
    private var mouseStopTimer: Timer?
    private var isGloballyPaused = false
    /// 输入监控是否可用（辅助功能权限）；无权限时禁止进入闲置置顶播放，避免无法退出
    private var inputMonitoringEnabled = false

    /// 鼠标停止判定阈值：宽限期（默认 5 秒）内停止移动超过该时长即取消退出，继续播放
    private static let mouseStopTimeout: TimeInterval = 2

    init(screen: NSScreen,
         displayID: String,
         configStore: ConfigStore,
         assetStore: AssetStore,
         engine: WallpaperEngine) {
        self.screen = screen
        self.displayID = displayID
        self.configStore = configStore
        self.assetStore = assetStore
        self.engine = engine
        self.displayConfig = configStore.config.displayConfigs.first { $0.displayID == displayID }
            ?? DisplayConfig(displayID: displayID)
    }

    /// 启动：创建壁纸窗口、恢复上次帧位置、进入活跃状态
    func start() {
        ensureDisplayConfigSaved()
        reloadWallpaperIfNeeded(force: true)
        restoreFramePosition()
        enterActive()
        logger.info("已启动：显示器 \(self.displayID)（\(self.screen.localizedName)），壁纸 \(self.wallpaperName)")
    }

    /// 停止：销毁窗口与计时器
    func shutdown() {
        idleTimer?.invalidate(); idleTimer = nil
        microStepTimer?.invalidate(); microStepTimer = nil
        cancelGrace()
        engine?.removeWindow(displayID: displayID)
    }

    /// 屏幕参数变化（分辨率/刷新率）时更新屏幕引用与窗口位置
    func updateScreen(_ newScreen: NSScreen) {
        screen = newScreen
        engine?.updateWindowFrame(displayID: displayID, screen: newScreen)
    }

    /// 检测到用户输入（键盘 / 强鼠标交互：点击、拖拽、滚动）：立即响应，不走宽限
    func inputDetected() {
        guard !isGloballyPaused else { return }
        switch state {
        case .idle:
            logger.info("显示器 \(self.displayID) 检测到输入，退出闲置")
            beginExit()
        case .active:
            resetIdleTimer()
        case .exiting:
            break // 退出中，忽略新输入
        }
    }

    /// 纯鼠标移动（弱输入）：闲置时启动/维持短暂进入宽限，宽限期内壁纸降层让位并暂停；
    /// 鼠标持续移动满宽限期才退出，移出或停止移动则恢复顶层播放
    func mouseMoved() {
        guard !isGloballyPaused else { return }
        switch state {
        case .idle:
            if graceTimer != nil {
                // 宽限已在进行：仅刷新停止看门狗（宽限计时器保持固定，需持续移动满宽限期才退出）
                restartMouseStopWatchdog()
            } else {
                startGrace()
            }
        case .active:
            resetIdleTimer()
        case .exiting:
            break // 退出中，忽略新输入
        }
    }

    /// 鼠标移出该显示器：取消短暂进入宽限，恢复顶层播放
    func mouseLeft() {
        guard graceTimer != nil else { return }
        logger.info("显示器 \(self.displayID) 鼠标移出，取消宽限，恢复顶层播放")
        resumePlaybackAfterGrace()
    }

    // MARK: - 全局暂停 / 恢复

    func pauseGlobally() {
        isGloballyPaused = true
        idleTimer?.invalidate(); idleTimer = nil
        microStepTimer?.invalidate(); microStepTimer = nil
        cancelGrace()
        engine?.pause(displayID: displayID)
    }

    func resumeGlobally() {
        isGloballyPaused = false
        switch state {
        case .active:
            engine?.pause(displayID: displayID)
            startMicroStepTimer()
            resetIdleTimer()
        case .idle:
            engine?.play(displayID: displayID)
        case .exiting:
            break
        }
    }

    /// 辅助功能权限变化：启用时重新开始闲置计时；禁用时取消闲置计时，
    /// 若正在置顶播放则立即退出（防止无输入检测时窗口永远置顶、用户无法操作）
    func setInputMonitoringEnabled(_ enabled: Bool) {
        guard enabled != inputMonitoringEnabled else { return }
        inputMonitoringEnabled = enabled
        if enabled {
            if state == .active {
                resetIdleTimer()
            }
            logger.info("输入监控已启用，闲置检测恢复")
        } else {
            idleTimer?.invalidate(); idleTimer = nil
            cancelGrace()
            if state == .idle {
                logger.info("输入监控不可用，退出闲置置顶播放")
                beginExit()
            }
        }
    }

    /// 配置变更后刷新壁纸（素材变化才重建窗口）
    func reloadWallpaperIfNeeded(force: Bool = false) {
        ensureDisplayConfigSaved()
        refreshDisplayConfigFromStore()
        let resolved = resolveAsset()
        guard force || engine?.assetID(for: displayID) != resolved?.id else { return }
        guard let resolved else { return }
        engine?.ensureWindow(displayID: displayID, screen: screen, asset: resolved)
        if force {
            engine?.seek(displayID: displayID, toFrame: displayConfig.lastFramePosition)
        }
    }

    // MARK: - 状态机

    private func enterActive() {
        state = .active
        engine?.pause(displayID: displayID)
        startMicroStepTimer()
        resetIdleTimer()
    }

    private func beginExit() {
        state = .exiting
        idleTimer?.invalidate(); idleTimer = nil
        microStepTimer?.invalidate(); microStepTimer = nil
        cancelGrace()

        switch configStore.config.exitMode {
        case .immediate:
            finishExit()
        case .fadeOut:
            logger.info("显示器 \(self.displayID) 退出闲置（渐隐）")
            engine?.fadeOut(displayID: displayID, duration: WallpaperEngine.fadeOutDuration) { [weak self] in
                self?.finishExit()
            }
        }
    }

    private func finishExit() {
        guard state == .exiting else { return }
        recordCurrentFrame()
        enterActive()
    }

    private func idleTimerFired() {
        guard state == .active, !isGloballyPaused else { return }
        guard inputMonitoringEnabled else { return } // 无输入监控（未授权）时不进入闲置置顶
        state = .idle
        microStepTimer?.invalidate(); microStepTimer = nil
        logger.info("显示器 \(self.displayID) 进入闲置，开始循环播放")
        engine?.play(displayID: displayID)
    }

    // MARK: - 短暂进入宽限

    /// 鼠标进入闲置显示器：壁纸暂停并降到底层让位（用户可立即看到屏幕内容），
    /// 同时启动固定时长宽限计时器与停止看门狗；移出/停止移动则恢复顶层播放，
    /// 持续移动满宽限期才判定为真实使用并退出
    private func startGrace() {
        let graceSeconds = max(0, configStore.config.briefEntryGraceSeconds)
        guard graceSeconds > 0 else {
            // 宽限期为 0：未启用宽限，鼠标进入立即退出
            beginExit()
            return
        }
        cancelGrace()
        logger.info("显示器 \(self.displayID) 鼠标进入，启动 \(Int(graceSeconds)) 秒宽限期，壁纸让位")
        // 暂停并降到底层（pause 内部将窗口降回桌面图标层级）
        engine?.pause(displayID: displayID)
        let grace = Timer(timeInterval: graceSeconds, repeats: false) { [weak self] _ in
            self?.graceTimerFired()
        }
        RunLoop.main.add(grace, forMode: .common)
        graceTimer = grace
        restartMouseStopWatchdog()
    }

    /// 鼠标持续移动满宽限期：判定为真实使用，恢复顶层后渐隐退出
    private func graceTimerFired() {
        graceTimer = nil
        mouseStopTimer = nil
        guard state == .idle, !isGloballyPaused else { return }
        logger.info("显示器 \(self.displayID) 鼠标持续移动超过宽限期，退出闲置")
        // 先恢复顶层，保证渐隐过程可见
        engine?.setOnTop(displayID: displayID, onTop: true)
        beginExit()
    }

    /// 鼠标停止移动：取消宽限，恢复顶层播放
    private func mouseStopped() {
        mouseStopTimer = nil
        guard state == .idle else { return }
        guard graceTimer != nil else { return }
        logger.info("显示器 \(self.displayID) 鼠标停止移动，取消宽限，恢复顶层播放")
        resumePlaybackAfterGrace()
    }

    /// 取消宽限并恢复顶层播放（鼠标移出/停止移动时调用）
    private func resumePlaybackAfterGrace() {
        guard graceTimer != nil || mouseStopTimer != nil else { return }
        cancelGrace()
        guard state == .idle, !isGloballyPaused else { return }
        // play 内部会将窗口升回顶层并继续播放
        engine?.play(displayID: displayID)
    }

    /// 刷新停止看门狗：每次移动重置阈值
    private func restartMouseStopWatchdog() {
        mouseStopTimer?.invalidate()
        let watchdog = Timer(timeInterval: Self.mouseStopTimeout, repeats: false) { [weak self] _ in
            self?.mouseStopped()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        mouseStopTimer = watchdog
    }

    private func cancelGrace() {
        graceTimer?.invalidate(); graceTimer = nil
        mouseStopTimer?.invalidate(); mouseStopTimer = nil
    }

    private func microStepFired() {
        guard state == .active, !isGloballyPaused else { return }
        let frames = max(1, configStore.config.microStepFrameCount)
        engine?.stepForward(displayID: displayID, frames: frames)
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        guard inputMonitoringEnabled else { return } // 无输入监控（未授权）时不启动闲置计时
        let seconds = max(1, configStore.config.idleTimeoutMinutes) * 60
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.idleTimerFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func startMicroStepTimer() {
        microStepTimer?.invalidate()
        let interval = max(1, configStore.config.microStepIntervalSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.microStepFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        microStepTimer = timer
    }

    // MARK: - 配置与素材

    /// 首次接入的显示器：写入默认配置
    private func ensureDisplayConfigSaved() {
        guard !configStore.config.displayConfigs.contains(where: { $0.displayID == displayID }) else { return }
        var dc = DisplayConfig(displayID: displayID)
        if let fallback = assetStore.fallbackAsset(for: .system) {
            dc.wallpaperType = .system
            dc.wallpaperAssetID = fallback.id
        }
        displayConfig = dc
        configStore.updateDisplayConfig(dc)
    }

    /// 从 ConfigStore 同步最新配置；素材被删除时自动回退到该类型第一个可用素材
    private func refreshDisplayConfigFromStore() {
        guard let stored = configStore.config.displayConfigs.first(where: { $0.displayID == displayID }) else { return }
        var fresh = stored
        if let asset = assetStore.asset(id: stored.wallpaperAssetID), asset.kind == stored.wallpaperType.assetKind {
            displayConfig = fresh
            return
        }
        if let fallback = assetStore.fallbackAsset(for: stored.wallpaperType.assetKind) {
            fresh.wallpaperAssetID = fallback.id
        }
        displayConfig = fresh
        if fresh != stored {
            configStore.updateDisplayConfig(fresh)
        }
    }

    private func resolveAsset() -> WallpaperAsset? {
        let config = configStore.config
        let type: WallpaperType
        let assetID: String
        if config.wallpaperConfigMode == .allDisplays {
            // 所有显示器模式：统一使用共享壁纸配置
            type = config.sharedWallpaperType
            assetID = config.sharedWallpaperAssetID
        } else {
            type = displayConfig.wallpaperType
            assetID = displayConfig.wallpaperAssetID
        }
        if let asset = assetStore.asset(id: assetID), asset.kind == type.assetKind {
            return asset
        }
        return assetStore.fallbackAsset(for: type.assetKind)
    }

    private func recordCurrentFrame() {
        let frame = engine?.currentFrame(displayID: displayID) ?? 0
        guard frame != displayConfig.lastFramePosition else { return }
        var dc = displayConfig
        dc.lastFramePosition = frame
        displayConfig = dc
        configStore.updateDisplayConfig(dc)
    }

    private func restoreFramePosition() {
        guard displayConfig.lastFramePosition > 0 else { return }
        engine?.seek(displayID: displayID, toFrame: displayConfig.lastFramePosition)
    }
}
