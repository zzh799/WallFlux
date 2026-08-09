import AppKit
import CoreAudio
import Darwin
import Foundation
import os

/// 媒体播放监测：其他应用正在输出声音（播放音乐/视频/直播等）时，命中显示器不进入闲置循环播放
///
/// 查询机制：CoreAudio 进程级公开 API（方案 B'，实现参考 sountop，MIT）：
/// - 枚举 `kAudioHardwarePropertyProcessObjectList` 得到所有音频客户端进程对象；
/// - 逐个进程查 `kAudioProcessPropertyIsRunningOutput`（是否正在出声）、
///   `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID`（进程身份）。
/// 100% 公开 API、零授权、macOS 14 起可用，不依赖私有框架与第三方 dylib。
/// 相比 MediaRemote「正在播放」通路，本方案能区分具体进程而不是设备级一刀切；
/// 局限：`IsRunningOutput` 只证明该进程的输出 IO 在跑，不保证信号非静音
/// （静音/极小音量流也算出声）——对「防闲置」足够。
///
/// 轮询节奏与 SmartPauseMonitor 一致（2 秒），查询在后台队列执行：
/// - 无出声进程（或查询失败）→ 不命中任何显示器；
/// - 有出声进程 → 窗口所在显示器命中；进程无窗口时（Chromium/Electron 的
///   audio utility 子进程、Safari 的 WebKit 子进程，如抖音、Chrome）按
///   Bundle 归属解析宿主应用窗口再判交（见 displayIDs）；两者都定位不到
///   （后台播放无窗口）才回退命中所有显示器（保守，避免壁纸覆盖媒体）。
///
/// 忽略名单（设置「媒体应用」页）：被用户忽略的应用即使正在出声也不命中，
/// 所在屏可正常进入闲置循环播放；开启忽略后立即重新评估放行。
/// 国内外常见音乐应用预置白名单（`MediaAppWhitelist`）：不预先占用忽略名单，
/// 应用真实出声时自动加入忽略名单（用户手动关闭过的键不再自动加入），
/// 名单可在「媒体应用」页只读查看。
///
/// 命中作用（配置 `mediaPlaybackKeepsActive` 开启时）：命中屏不进入闲置循环播放；
/// 媒体开始时若该屏正处于闲置播放则立即退出，壁纸让位。不影响微跳
/// （与全屏暂停微跳是两个独立行为）。发现历史与「正在播放」列表始终维护
/// （供设置「媒体应用」页展示），与开关无关。
final class MediaPlaybackMonitor: ObservableObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "MediaPlaybackMonitor")
    private let configStore: ConfigStore
    private weak var screenManager: ScreenManager?

    /// 轮询间隔（秒，与全屏检测一致）
    private static let pollInterval: TimeInterval = 2
    /// 发现历史「最近播放时间」刷新的最小间隔（秒）：限频持久化，避免每次轮询都写配置
    private static let historyRefreshInterval: TimeInterval = 30

    /// 当前正在出声的应用（含被忽略的，设置页「正在播放」标记用）
    @Published private(set) var nowPlayingApps: [AudioAppRecord] = []

    private var pollTimer: Timer?
    /// 最近一次命中列表（避免重复推送）
    private var lastMediaPlaybackDisplayIDs: Set<String> = []
    /// 上一轮查询是否仍在进行（在途时跳过本轮）
    private var queryInFlight = false

    init(configStore: ConfigStore, screenManager: ScreenManager) {
        self.configStore = configStore
        self.screenManager = screenManager
    }

    func start() {
        // 清除历史里系统音频基础设施的残留记录（com.apple.audio.* 已不在检测范围内）
        let staleKeys = configStore.config.audioAppHistory
            .filter { $0.key.hasPrefix("com.apple.audio.") }
            .map(\.key)
        if !staleKeys.isEmpty {
            configStore.update { config in
                config.audioAppHistory.removeAll { staleKeys.contains($0.key) }
            }
        }

        // 配置变更：开关开启时立即重测；关闭时立即清空命中（不等待下一个轮询周期）；
        // 忽略名单变化时立即重测，让被忽略的应用立刻放行
        configStore.addChangeHandler { [weak self] in
            guard let self else { return }
            if self.configStore.config.mediaPlaybackKeepsActive {
                self.poll()
            } else {
                self.pushDisplayIDs([])
            }
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
        logger.info("媒体播放监测已启动（CoreAudio 进程级检测）")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 轮询

    /// 每 2 秒轮询：枚举出声进程 → 计算命中显示器 → 推送 ScreenManager + 刷新发现历史
    /// （发现历史与开关无关：即使「媒体保持活跃」关闭也持续记录本机播放过声音的应用）
    private func poll() {
        guard !queryInFlight else { return } // 上轮仍在查询，跳过本轮
        queryInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = self?.querySnapshot() ?? PlaybackSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryInFlight = false
                self.applySnapshot(snapshot)
            }
        }
    }

    private func pushDisplayIDs(_ ids: Set<String>) {
        guard ids != lastMediaPlaybackDisplayIDs else { return }
        lastMediaPlaybackDisplayIDs = ids
        screenManager?.applyMediaPlaybackDisplayIDs(ids)
    }

    /// 应用一轮查询结果（主线程）：推送命中显示器 + 更新「正在播放」列表与发现历史
    private func applySnapshot(_ snapshot: PlaybackSnapshot) {
        if configStore.config.mediaPlaybackKeepsActive {
            pushDisplayIDs(snapshot.displayIDs)
        } else {
            pushDisplayIDs([])
        }
        let now = Date()
        nowPlayingApps = snapshot.processes.map {
            AudioAppRecord(key: $0.key, bundleID: $0.bundleID, name: $0.name, lastPlayedAt: now)
        }
        updateDiscoveryHistory(playing: snapshot.processes, now: now)
        applyAutoIgnore(playing: snapshot.processes)
    }

    // MARK: - 白名单自动忽略

    /// 白名单应用真实出声后自动加入忽略名单：命中任一白名单键即忽略，
    /// 该应用所在屏可正常进入闲置循环播放（听歌时壁纸照常循环）。
    /// 仅自动追加「不在忽略名单且用户未手动关闭过」的键：
    /// 用户曾在列表里关闭过的键（`mediaWhitelistUserExcludedKeys`）不再自动加入，
    /// 尊重用户选择；已忽略的键没有变化时不会触发写入。
    private func applyAutoIgnore(playing: [AudioOutputProcess]) {
        let excluded = Set(configStore.config.mediaWhitelistUserExcludedKeys)
        let whitelistKeys = Set(MediaAppWhitelist.allKeys)
        let toAdd = playing.map(\.key).filter { key in
            whitelistKeys.contains(key) && !excluded.contains(key)
        }
        guard !toAdd.isEmpty else { return }
        configStore.update { config in
            for key in toAdd where !config.ignoredAudioAppKeys.contains(key) {
                config.ignoredAudioAppKeys.append(key)
            }
        }
    }

    // MARK: - 发现历史（设置「媒体应用」页）

    /// 合并当前出声进程到发现历史：新应用追加，名称变化刷新，最近播放时间限频刷新。
    /// 仅在有实质变化时写 ConfigStore（避免每次轮询触发全局配置变更回调）。
    private func updateDiscoveryHistory(playing: [AudioOutputProcess], now: Date) {
        var history = configStore.config.audioAppHistory
        var changed = false
        for proc in playing {
            if let idx = history.firstIndex(where: { $0.key == proc.key }) {
                if history[idx].name != proc.name {
                    history[idx].name = proc.name
                    changed = true
                }
                if now.timeIntervalSince(history[idx].lastPlayedAt) >= Self.historyRefreshInterval {
                    history[idx].lastPlayedAt = now
                    changed = true
                }
            } else {
                history.append(AudioAppRecord(key: proc.key, bundleID: proc.bundleID,
                                              name: proc.name, lastPlayedAt: now))
                changed = true
            }
        }
        guard changed else { return }
        configStore.update { $0.audioAppHistory = history }
    }

    // MARK: - 查询与命中计算（后台队列执行）

    /// 枚举正在出声的音频客户端进程，并计算命中的显示器集合
    private func querySnapshot() -> PlaybackSnapshot {
        let processes = Self.outputAudioProcesses()
        guard !processes.isEmpty else {
            logger.info("当前无进程正在输出声音")
            return PlaybackSnapshot()
        }
        let ignored = Set(configStore.config.ignoredAudioAppKeys)
        let visible = processes.filter { !ignored.contains($0.key) }
        let displayIDs = displayIDs(for: visible)
        if !visible.isEmpty {
            logger.info("检测到 \(visible.count) 个进程正在输出声音（\(visible.map(\.name).joined(separator: "、"), privacy: .public)），命中 \(displayIDs.count) 个显示器")
        } else if !processes.isEmpty {
            logger.info("\(processes.count) 个出声进程全部在忽略名单中，不命中任何显示器")
        }
        return PlaybackSnapshot(displayIDs: displayIDs, processes: processes)
    }

    // MARK: - CoreAudio 进程枚举（公开 API，实现参考 sountop，MIT）

    /// 单个音频客户端进程的身份快照
    private struct AudioOutputProcess {
        let pid: Int32
        let bundleID: String?
        let name: String

        /// 稳定身份键：优先 bundle ID；无 bundle ID（命令行工具等）以进程名兜底
        var key: String { bundleID ?? "proc:\(name)" }
    }

    private struct PlaybackSnapshot {
        var displayIDs: Set<String> = []
        var processes: [AudioOutputProcess] = []
    }

    /// 枚举所有音频客户端进程对象，返回「正在输出声音」的进程（含自己的 PID 过滤）
    private static func outputAudioProcesses() -> [AudioOutputProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processIDs) == noErr else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [AudioOutputProcess] = []
        for objectID in processIDs {
            guard let pid: Int32 = audioProcessProperty(objectID, kAudioProcessPropertyPID),
                  pid > 0, pid != ownPID else { continue }
            let isRunningOutput: UInt32 = audioProcessProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
            guard isRunningOutput != 0 else { continue }
            let bundleID = audioProcessCFStringProperty(objectID, kAudioProcessPropertyBundleID)
            // 音频驱动等系统基础设施（com.apple.audio.*）不是用户媒体应用，排除，避免误判为媒体播放
            if let bundleID, bundleID.hasPrefix("com.apple.audio.") { continue }
            result.append(AudioOutputProcess(pid: pid, bundleID: bundleID, name: displayName(pid: pid)))
        }
        return result
    }

    /// 读取进程对象的数值属性（PID / IsRunningOutput 等）
    private static func audioProcessProperty<T>(_ objectID: AudioObjectID,
                                                _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let valuePtr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { valuePtr.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, valuePtr)
        guard status == noErr else { return nil }
        return valuePtr.pointee
    }

    /// 读取进程对象的 CFString 属性（BundleID 等；AudioObjectGetPropertyData 返回 +1 引用）
    private static func audioProcessCFStringProperty(_ objectID: AudioObjectID,
                                                     _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let unmanaged = value else { return nil }
        let string = unmanaged.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    /// 进程显示名：优先 NSRunningApplication 的本地化名称；
    /// 无名称的辅助/实用进程（Chrome 音频服务等）按可执行路径定位所属 App 的
    /// Bundle ID，再归到宿主应用（com.google.Chrome.helper → Google Chrome）。
    private static func displayName(pid: Int32) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        if let path = executablePath(pid: pid),
           let helperBundleID = appBundleID(executablePath: path),
           let host = hostingApp(bundleID: helperBundleID) {
            return host.name
        }
        return "PID \(pid)"
    }

    /// 进程可执行路径（proc_pidpath，libproc 公开接口）
    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 从可执行路径向上找到进程所属的第一个 App 包（.app / .xpc），读取其 bundle identifier
    private static func appBundleID(executablePath: String) -> String? {
        var dir = (executablePath as NSString).deletingLastPathComponent
        while dir != "/" && dir != "." {
            if dir.hasSuffix(".app") || dir.hasSuffix(".xpc") {
                if let bundle = Bundle(path: dir), let id = bundle.bundleIdentifier, !id.isEmpty {
                    return id
                }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 宿主应用：在运行中的应用里找 bundle ID 是给定 ID 前缀（以 "." 分界）的最短匹配，
    /// 如 com.bytedance.douyin.desktop.helper（audio utility 子进程）→
    /// com.bytedance.douyin.desktop（抖音）。hostingApp 供命中计算（displayIDs）
    /// 定位宿主窗口与显示名（displayName）共用。
    private struct HostApp {
        let bundleID: String
        let pid: Int32?
        let name: String
    }

    private static func hostingApp(bundleID: String) -> HostApp? {
        let candidates = NSWorkspace.shared.runningApplications
            .compactMap { app -> HostApp? in
                guard let hostID = app.bundleIdentifier, hostID != bundleID,
                      bundleID.hasPrefix(hostID + "."),
                      let name = app.localizedName, !name.isEmpty else { return nil }
                return HostApp(bundleID: hostID, pid: app.processIdentifier, name: name)
            }
            .sorted { $0.bundleID.count < $1.bundleID.count } // 最短前缀即最直接的宿主
        return candidates.first
    }

    /// 命中显示器计算：出声进程的 layer 0 普通窗口与各 NSScreen.frame 判交。
    /// Chromium/Electron 类应用（抖音、Chrome、微信等）音频由无窗口的
    /// utility 子进程输出（窗口归主应用），故进程无窗口时按 Bundle 归属解析
    /// 宿主应用窗口再判交（与 displayName 同源逻辑）；两者都定位不到（如后台
    /// 播放无窗口）才回退所有显示器（保守，避免壁纸覆盖媒体）。
    /// 全部被忽略时传入空数组，返回空集合（不命中任何显示器）。
    private func displayIDs(for processes: [AudioOutputProcess]) -> Set<String> {
        let allDisplayIDs = Set(NSScreen.screens.map { String($0.fluxDisplayID) })
        guard !processes.isEmpty else { return [] } // 全部被忽略：不命中任何显示器
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return allDisplayIDs
        }
        var result = Set<String>()
        for proc in processes {
            // 优先按进程自身窗口；layer 0 普通窗口（不透明、有实际尺寸），
            // 壁纸窗口闲置置顶播放时 layer 1000、其余时间隐藏，均不会命中筛选
            let procRects = ordinaryWindowRects(windows, ownedBy: proc.pid)
            if !procRects.isEmpty {
                result.formUnion(displaysHit(by: procRects))
            } else if let bundleID = proc.bundleID,
                      let host = Self.hostingApp(bundleID: bundleID),
                      let hostPid = host.pid {
                let hostRects = ordinaryWindowRects(windows, ownedBy: hostPid)
                guard !hostRects.isEmpty else {
                    logger.info("\(proc.name, privacy: .public)（pid \(proc.pid)）及其宿主 \(host.name, privacy: .public) 均无窗口，回退所有显示器")
                    return allDisplayIDs
                }
                logger.info("\(proc.name, privacy: .public)（pid \(proc.pid)）无窗口，按 Bundle 归属使用宿主 \(host.name, privacy: .public) 的窗口")
                result.formUnion(displaysHit(by: hostRects))
            } else {
                logger.info("\(proc.name, privacy: .public)（pid \(proc.pid)）未找到窗口，回退所有显示器")
                return allDisplayIDs
            }
        }
        return result
    }

    /// 进程所属 layer 0 普通窗口的 bounds 数组（CGWindowList 全局显示坐标，
    /// 原点在主屏左上角、y 向下，与 AppKit 坐标不同，判交前需翻转）
    private func ordinaryWindowRects(_ windows: [[String: Any]], ownedBy pid: Int32) -> [CGRect] {
        windows.compactMap { win in
            guard let owner = win[kCGWindowOwnerPID as String] as? Int, owner == Int(pid) else { return nil }
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }
            guard let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0 else { return nil }
            guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                  bounds["Width"] ?? 0 > 50, bounds["Height"] ?? 0 > 50 else { return nil }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                          width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
    }

    /// 与各 NSScreen.frame 判交得命中屏集合：窗口需先换算为 AppKit 坐标
    /// （水平并排布局下高度相同时直接判交也正确，但垂直堆叠且各屏高度不同
    /// 时会错锁相邻屏幕，统一按 appKitRectFromCGWindowList 翻转再判交）
    private func displaysHit(by rects: [CGRect]) -> Set<String> {
        let appKitRects = rects.map { $0.appKitRectFromCGWindowList() }
        var result = Set<String>()
        for screen in NSScreen.screens {
            if appKitRects.contains(where: { $0.intersects(screen.frame) }) {
                result.insert(String(screen.fluxDisplayID))
            }
        }
        return result
    }
}

