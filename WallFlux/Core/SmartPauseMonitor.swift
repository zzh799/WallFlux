import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import os

/// 智能暂停条件监测（设计文档 §2）
///
/// 聚合五个全局条件的实时状态，推送给 ScreenManager 应用到各显示器：
/// 系统睡眠 / 显示器睡眠 / 低电量模式 / 电池供电 / 低电量阈值（命中作用于所有屏）。
///
/// 二值暂停模型：任一启用条件命中 → 完全暂停（停播放 + 停微跳），无降频中间态。
/// 总开关 `smartPauseEnabled` 关闭时所有条件不再评估，回归纯手动控制。
/// 全屏应用不属于智能暂停：它是微跳模式的独立行为（存在全屏应用时该屏暂停微跳、
/// 闲置屏照常播放），由同一 2 秒轮询检测并单独推送，不随智能暂停总开关关闭。
final class SmartPauseMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "SmartPauseMonitor")
    private let configStore: ConfigStore
    private weak var screenManager: ScreenManager?

    /// 全屏轮询间隔（秒，设计 §2.3）
    private static let fullscreenPollInterval: TimeInterval = 2
    /// 低电量恢复滞后：恢复线 = 暂停线（阈值）+ 5%（设计 §2.4 防抖滞后）
    private static let lowBatteryHysteresis: Double = 5

    /// 当前命中的智能暂停原因（全局条件，UI 展示用）
    @Published private(set) var activeReasons: [SmartPauseReason] = []

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var powerSourceSource: CFRunLoopSource?
    /// 最近一次全屏命中列表（避免重复推送）
    private var lastFullscreenDisplayIDs: Set<String> = []
    /// 最近一次推送的全局条件集合
    private var globalReasons: Set<SmartPauseReason> = []

    // 条件实时状态
    private var systemSleeping = false
    private var displayBlanked = false
    private var lowPowerModeEnabled = false
    private var isBatteryPowered = false
    private var batteryPercent = 100.0
    /// 低电量滞后状态：暂停线 = 阈值，恢复线 = 阈值 + 5%
    private var lowBatteryActive = false
    /// 全屏检测开关是否生效（配置变更时据此判断是否立即重测全屏）
    private var fullscreenDetectionEnabled = false

    /// CGDisplay 重构回调（blanking / 唤醒检测，需与移除时使用同一函数指针）
    private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, _, userInfo in
        guard let userInfo else { return }
        let monitor = Unmanaged<SmartPauseMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.refreshDisplayBlankedState()
    }

    init(configStore: ConfigStore, screenManager: ScreenManager) {
        self.configStore = configStore
        self.screenManager = screenManager
    }

    func start() {
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshPowerState()
        fullscreenDetectionEnabled = isFullscreenDetectionEnabled

        // 系统睡眠 / 唤醒（设计 §2.4：睡眠前全部屏暂停；唤醒后重置闲置计时为 active 再恢复）
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemSleeping = true
            self?.evaluateGlobalConditions()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleSystemWake()
        })

        // 显示器睡眠：实测 NSWorkspace screensDidSleep/Wake 与 CGDisplay 重构回调在本环境均不触发，
        // 改由 2 秒轮询 CGDisplayIsAsleep 检测（与全屏检测共用定时器）；
        // 保留重构回调作为事件驱动加速（部分系统上显示器睡眠/唤醒会触发）
        CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())

        // 低电量模式（设计 §2.4：直接跟随系统状态）
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.evaluateGlobalConditions()
        })

        // 电源状态变化（电池供电 / 电量百分比，设计 §2.4）
        setupPowerSourceNotification()

        // 配置变更（总开关 / 条件开关 / 低电量阈值）→ 重新评估
        configStore.addChangeHandler { [weak self] in
            self?.handleConfigChange()
        }

        // 轮询定时器（设计 §2.4）：每 2 秒检测显示器睡眠（CGDisplayIsAsleep）与全屏窗口
        let timer = Timer(timeInterval: Self.fullscreenPollInterval, repeats: true) { [weak self] _ in
            self?.pollFullscreen()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        evaluateAll()
        logger.info("智能暂停监测已启动")
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        if let powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceSource, .commonModes)
        }
        powerSourceSource = nil
    }

    // MARK: - 系统睡眠 / 唤醒

    /// 系统唤醒：先重置所有显示器为活跃（避免唤醒后壁纸立即置顶播放），再清除睡眠条件
    private func handleSystemWake() {
        screenManager?.handleSystemWake()
        systemSleeping = false
        evaluateGlobalConditions()
    }

    // MARK: - 显示器睡眠

    /// 校验各显示器 blanking 状态（CGDisplayIsAsleep；轮询 + 重构回调双路径，设计 §2.3）
    private func refreshDisplayBlankedState() {
        let anyAsleep = NSScreen.screens.contains { CGDisplayIsAsleep($0.fluxDisplayID) != 0 }
        guard anyAsleep != displayBlanked else { return }
        displayBlanked = anyAsleep
        evaluateGlobalConditions()
    }

    // MARK: - 电源状态

    private func setupPowerSourceNotification() {
        // IOPS 电源变化通知（回调挂主线程 run loop）
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SmartPauseMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.refreshPowerState()
            monitor.evaluateGlobalConditions()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            logger.error("IOPS 电源通知创建失败")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceSource = source
    }

    /// 读取电源状态：是否电池供电 + 电量百分比（无电池设备默认 100%，两个条件均不触发）
    private func refreshPowerState() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            isBatteryPowered = false
            batteryPercent = 100
            return
        }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 100
            let max = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
            isBatteryPowered = state == kIOPSBatteryPowerValue
            batteryPercent = max > 0 ? current / max * 100 : 100
            return
        }
        isBatteryPowered = false
        batteryPercent = 100
    }

    // MARK: - 条件评估

    private var isFullscreenDetectionEnabled: Bool {
        configStore.config.microStepPauseOnFullscreen
    }

    private func handleConfigChange() {
        // 全屏开关变化：立即重测并推送（否则等下一个轮询周期）
        let enabled = isFullscreenDetectionEnabled
        if enabled != fullscreenDetectionEnabled {
            fullscreenDetectionEnabled = enabled
            pollFullscreen()
        }
        evaluateGlobalConditions()
    }

    /// 汇总全局条件（系统睡眠 / 显示器睡眠 / 低电量模式 / 电池供电 / 低电量阈值）
    private func evaluateGlobalConditions() {
        let config = configStore.config
        var reasons: Set<SmartPauseReason> = []
        if config.smartPauseEnabled {
            if config.pauseOnSleep && systemSleeping {
                reasons.insert(.systemSleep)
            }
            if config.pauseOnDisplaySleep && displayBlanked {
                reasons.insert(.displaySleep)
            }
            if config.pauseOnLowPowerMode && lowPowerModeEnabled {
                reasons.insert(.lowPowerMode)
            }
            if config.pauseOnBattery && isBatteryPowered {
                reasons.insert(.batteryPower)
            }
            if config.pauseOnLowBattery {
                evaluateLowBattery()
                if lowBatteryActive {
                    reasons.insert(.lowBattery)
                }
            }
        }
        globalReasons = reasons
        pushState()
    }

    /// 低电量阈值滞后评估（设计 §2.4）：暂停线 = 阈值；恢复线 = 阈值 + 5%。
    /// 与电源状态无关，插电充电时同样评估。阈值与恢复线之间保持现状，避免边界抖动。
    private func evaluateLowBattery() {
        let threshold = configStore.config.lowBatteryThresholdPercent
        let resumeLine = min(threshold + Self.lowBatteryHysteresis, 100)
        if batteryPercent < threshold {
            lowBatteryActive = true
        } else if batteryPercent >= resumeLine {
            lowBatteryActive = false
        }
    }

    /// 每 2 秒轮询：检测全屏/最大化窗口命中的显示器（供微跳暂停使用），
    /// 同时顺带刷新显示器睡眠状态（CGDisplayIsAsleep 轮询，通知不可靠）
    private func pollFullscreen() {
        refreshDisplayBlankedState()
        let ids: Set<String>
        if isFullscreenDetectionEnabled {
            ids = detectFullscreenDisplayIDs()
        } else {
            ids = []
        }
        guard ids != lastFullscreenDisplayIDs else { return }
        lastFullscreenDisplayIDs = ids
        pushState()
    }

    /// 全部条件重新评估（启动时）
    private func evaluateAll() {
        evaluateGlobalConditions()
        pollFullscreen()
    }

    private func pushState() {
        screenManager?.applySmartPause(globalReasons: globalReasons)
        screenManager?.applyFullscreenDisplayIDs(lastFullscreenDisplayIDs)
        activeReasons = SmartPauseReason.allCases.filter { globalReasons.contains($0) }
    }

    // MARK: - 全屏检测

    /// 检测命中全屏/最大化的显示器集合（供微跳暂停：该屏活跃时不微跳）。
    /// 判定：layer 0 普通窗口的 bounds 完全覆盖某屏工作区（visibleFrame，不含菜单栏/程序坞）。
    /// 真正的 macOS 全屏（覆盖完整 frame 含菜单栏区域）以及最大化窗口（铺满工作区）均命中；
    /// 锁屏窗口（layer 2004）不命中。窗口坐标与 AppKit 坐标系不同，需换算。
    private func detectFullscreenDisplayIDs() -> Set<String> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        // layer 0 普通窗口（不透明、有实际尺寸）；壁纸窗口位于桌面图标层级（layer < 0），不会命中
        let candidates = windows.filter { win in
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0 else { return false }
            guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                  bounds["Width"] ?? 0 > 50, bounds["Height"] ?? 0 > 50 else { return false }
            return true
        }
        guard !candidates.isEmpty else { return [] }

        var result = Set<String>()
        for screen in NSScreen.screens {
            let visibleFrame = screen.visibleFrame
            for win in candidates {
                guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let windowRect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                                        width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                if windowRect.coversAppKitRect(visibleFrame) {
                    result.insert(String(screen.fluxDisplayID))
                    break
                }
            }
        }
        return result
    }
}

/// CGWindowList 窗口坐标（全局显示坐标，原点在主屏左上角、y 向下）
/// 与 AppKit 坐标（原点在主屏左下角、y 向上）互转。
extension CGRect {
    /// 将 CGWindowList 坐标下的矩形换算为 AppKit 坐标（垂直翻转）
    func appKitRectFromCGWindowList() -> CGRect {
        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
        return CGRect(x: minX, y: mainHeight - maxY, width: width, height: height)
    }

    /// 本矩形（CGWindowList 坐标）是否完全覆盖目标 AppKit 矩形（含 1pt 容差，兼容取整差异）
    func coversAppKitRect(_ target: CGRect) -> Bool {
        let window = appKitRectFromCGWindowList()
        let tolerance: CGFloat = 1
        return window.minX - tolerance <= target.minX
            && window.minY - tolerance <= target.minY
            && window.maxX + tolerance >= target.maxX
            && window.maxY + tolerance >= target.maxY
    }
}
