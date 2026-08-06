import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import os
import Foundation

/// 全局输入事件监听（CGEventTap）
///
/// - 需要辅助功能权限；无权限时 tap 创建失败，需引导用户授权
/// - tap 被系统终止（超时/用户输入）后自动重连
/// - 所有回调均在主线程执行
final class IdleDetector: ObservableObject {
    /// 输入事件类型
    enum InputKind {
        case mouseMoved   // 鼠标移动 / 点击 / 滚动
        case keyPressed   // 键盘输入
    }

    /// 输入事件回调（主线程）
    var onInput: ((InputKind) -> Void)?

    @Published private(set) var isTrusted = false
    @Published private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reconnectTimer: Timer?
    private var lastTrustedState = false
    private var lastFocusQuery = Date.distantPast
    private var cachedFocusDisplayID: String?
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "IdleDetector")

    private let eventMask: CGEventMask
    private let tapCallback: CGEventTapCallBack

    init() {
        // 监听鼠标移动/拖拽/点击/滚动，以及键盘按键/修饰键
        var mask: CGEventMask = 0
        for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                     .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
                     .keyDown, .flagsChanged] {
            mask |= CGEventMask(1 << type.rawValue)
        }
        eventMask = mask

        tapCallback = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let detector = Unmanaged<IdleDetector>.fromOpaque(userInfo).takeUnretainedValue()
            detector.handleEvent(type: type)
            return Unmanaged.passUnretained(event)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshTrust()
        ensureTap()

        // 周期性检查：权限变化或 tap 被终止时重连
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTrust()
            self?.ensureTap()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        destroyTap()
    }

    // MARK: - 键盘焦点窗口

    /// 键盘聚焦窗口所在显示器的 displayID（AX 查询，0.5 秒节流缓存）
    /// 查询失败（无焦点窗口/权限缺失/系统繁忙）返回 nil，由调用方决定回退策略
    func focusedDisplayID() -> String? {
        let now = Date()
        if now.timeIntervalSince(lastFocusQuery) < 0.5 { return cachedFocusDisplayID }
        lastFocusQuery = now
        cachedFocusDisplayID = queryFocusedDisplayID()
        return cachedFocusDisplayID
    }

    /// 前台应用最前窗口所在显示器的 displayID（CGWindowList，无需辅助功能权限）
    /// 作为 AX 查询失败的兜底；前台应用无普通窗口时返回 nil
    func frontmostWindowDisplayID() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // 前台应用的普通窗口（layer 0、不透明、有实际尺寸），数组顺序即 z 序（最前在前）
        let candidates = windows.filter { win in
            guard let pid = win[kCGWindowOwnerPID as String] as? Int, pid == frontmost.processIdentifier else { return false }
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0 else { return false }
            guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                  bounds["Width"] ?? 0 > 50, bounds["Height"] ?? 0 > 50 else { return false }
            return true
        }
        guard let first = candidates.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else {
            return nil
        }
        let center = CGPoint(x: x + w / 2, y: y + h / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return nil }
        return String(screen.fluxDisplayID)
    }

    private func queryFocusedDisplayID() -> String? {
        // 系统级聚焦应用 → 聚焦窗口 → 窗口位置/尺寸 → 中心点所在屏幕
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef)
        guard appErr == .success, let focusedApp = focusedAppRef else {
            logger.error("AX 查询聚焦应用失败: \(appErr.rawValue)")
            return nil
        }

        let appElement = focusedApp as! AXUIElement
        var focusedWindowRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard winErr == .success, let focusedWindow = focusedWindowRef else {
            logger.error("AX 查询聚焦窗口失败: \(winErr.rawValue)")
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef)
        let sizeErr = AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef)
        guard posErr == .success, sizeErr == .success, let positionRef, let sizeRef else {
            logger.error("AX 查询窗口位置/尺寸失败: pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
            return nil
        }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            logger.error("AX 窗口位置/尺寸取值失败")
            return nil
        }

        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else {
            logger.error("AX 窗口中心 \(String(describing: center)) 不匹配任何屏幕")
            return nil
        }
        return String(screen.fluxDisplayID)
    }

    // MARK: - 私有

    private func refreshTrust() {
        isTrusted = AXIsProcessTrusted()
    }

    private func ensureTap() {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        destroyTap()
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrustedState {
            if trusted {
                logger.info("已获得辅助功能权限，创建输入监听")
            } else {
                logger.info("无辅助功能权限，输入监听未启用（用户可在设置中授权）")
            }
            lastTrustedState = trusted
        }
        guard trusted else { return }
        createTap()
    }

    private func createTap() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .listenOnly,
                                             eventsOfInterest: eventMask,
                                             callback: tapCallback,
                                             userInfo: userInfo) else {
            logger.error("CGEventTap 创建失败")
            return
        }
        logger.info("输入监听已创建")
        tap = newTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
    }

    private func destroyTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.tap = nil
        runLoopSource = nil
    }

    private func handleEvent(type: CGEventType) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统终止了 tap，稍后自动重连
            DispatchQueue.main.async { [weak self] in
                self?.ensureTap()
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            onInput?(.mouseMoved)
        case .keyDown, .flagsChanged:
            onInput?(.keyPressed)
        default:
            break
        }
    }
}
