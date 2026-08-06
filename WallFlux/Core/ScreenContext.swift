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
    private var isGloballyPaused = false

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
        engine?.removeWindow(displayID: displayID)
    }

    /// 屏幕参数变化（分辨率/刷新率）时更新屏幕引用与窗口位置
    func updateScreen(_ newScreen: NSScreen) {
        screen = newScreen
        engine?.updateWindowFrame(displayID: displayID, screen: newScreen)
    }

    /// 检测到用户输入（鼠标在显示器上 / 全局键盘）
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

    // MARK: - 全局暂停 / 恢复

    func pauseGlobally() {
        isGloballyPaused = true
        idleTimer?.invalidate(); idleTimer = nil
        microStepTimer?.invalidate(); microStepTimer = nil
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
        state = .idle
        microStepTimer?.invalidate(); microStepTimer = nil
        logger.info("显示器 \(self.displayID) 进入闲置，开始循环播放")
        engine?.play(displayID: displayID)
    }

    private func microStepFired() {
        guard state == .active, !isGloballyPaused else { return }
        let frames = max(1, configStore.config.microStepFrameCount)
        engine?.stepForward(displayID: displayID, frames: frames)
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
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
