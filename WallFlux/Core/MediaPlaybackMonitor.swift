import AppKit
import Foundation
import os

/// 媒体播放监测：其他应用播放视频/直播/音乐时，命中显示器不进入闲置循环播放
///
/// 查询机制：以 `/usr/bin/perl` 启动打包的 `mediaremote-mini.pl` 加载
/// `MediaRemoteMini.dylib`（第三方组件，GPL-3.0，来源与构建见
/// `Resources/MediaRemote/README.md`）。WallFlux 自身直连 MediaRemote 私有框架
/// 会被 mediaremoted 以「无 entitlement」拒绝（非 Apple 签名进程无法取得
/// 读取权限），而系统 perl 带 Apple 签名 entitlement（mediaremoted 授予
/// entitlements=512），由 perl 作为宿主加载 dylib 即可正常查询。
///
/// 轮询节奏与 SmartPauseMonitor 一致（2 秒），查询在后台队列执行：
/// - 无播放媒体（或查询失败/超时）→ 不命中任何显示器；
/// - 有播放媒体 → 播放进程窗口所在显示器命中；找不到窗口（如 Safari 的
///   WebKit.GPU 子进程播放）时回退命中所有显示器（保守，避免壁纸覆盖媒体）。
///
/// 命中作用（配置 `mediaPlaybackKeepsActive` 开启时）：命中屏不进入闲置循环播放；
/// 媒体开始时若该屏正处于闲置播放则立即退出，壁纸让位。不影响微跳
/// （与全屏暂停微跳是两个独立行为）。
final class MediaPlaybackMonitor {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "MediaPlaybackMonitor")
    private let configStore: ConfigStore
    private weak var screenManager: ScreenManager?

    /// 轮询间隔（秒，与全屏检测一致）
    private static let pollInterval: TimeInterval = 2
    /// 子进程超时（秒）：perl 挂起时终止本轮，避免查询堆积
    private static let processTimeout: TimeInterval = 3

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
        // 配置变更：开关开启时立即重测；关闭时立即清空命中（不等待下一个轮询周期）
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
        logger.info("媒体播放监测已启动")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - 轮询

    /// 每 2 秒轮询：查询正在播放的媒体 → 计算命中显示器 → 推送 ScreenManager
    private func poll() {
        guard configStore.config.mediaPlaybackKeepsActive else { return }
        guard !queryInFlight else { return } // 上轮仍在查询，跳过本轮
        queryInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ids = self?.queryNowPlayingDisplayIDs() ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.queryInFlight = false
                self.pushDisplayIDs(ids)
            }
        }
    }

    private func pushDisplayIDs(_ ids: Set<String>) {
        guard ids != lastMediaPlaybackDisplayIDs else { return }
        lastMediaPlaybackDisplayIDs = ids
        screenManager?.applyMediaPlaybackDisplayIDs(ids)
    }

    // MARK: - 查询与命中计算（后台队列执行）

    /// 查询正在播放的媒体进程，并计算命中的显示器集合；无播放/失败时返回空集合
    private func queryNowPlayingDisplayIDs() -> Set<String> {
        guard let info = queryNowPlaying() else { return [] }
        guard info.playing, info.processIdentifier > 0 else { return [] }
        let ids = displayIDs(for: info.processIdentifier)
        logger.info("检测到媒体播放（pid \(info.processIdentifier)），命中 \(ids.count) 个显示器")
        return ids
    }

    /// 调用 perl 辅助组件查询「正在播放」信息；输出缺失/异常时返回 nil（视为无播放）
    private func queryNowPlaying() -> NowPlayingInfo? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let scriptPath = resources.appendingPathComponent("mediaremote-mini.pl").path
        let dylibPath = resources.appendingPathComponent("MediaRemoteMini.dylib").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, dylibPath, "adapter_get_env"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe() // 吞掉 stderr，避免日志噪声
        do {
            try process.run()
        } catch {
            logger.error("辅助进程启动失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        // 超时兜底：perl 挂起时终止本轮（readDataToEndOfFile 随即返回）
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.processTimeout) { [weak process] in
            if process?.isRunning == true {
                process?.terminate()
            }
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "null" else { return nil }
        guard let payload = text.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            logger.error("辅助进程输出解析失败")
            return nil
        }
        return NowPlayingInfo(playing: dict["playing"] as? Bool ?? false,
                              processIdentifier: dict["processIdentifier"] as? Int ?? 0)
    }

    /// 播放进程窗口所在显示器集合；找不到窗口时回退所有显示器
    /// （后台播放无窗口、Safari 的 WebKit.GPU 子进程播放等场景无法定位媒体位置）
    private func displayIDs(for processID: Int) -> Set<String> {
        let allDisplayIDs = Set(NSScreen.screens.map { String($0.fluxDisplayID) })
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return allDisplayIDs
        }
        // layer 0 普通窗口（不透明、有实际尺寸）；壁纸窗口位于桌面图标层级（layer < 0）
        let pidWindows = windows.filter { win in
            guard let owner = win[kCGWindowOwnerPID as String] as? Int, owner == processID else { return false }
            guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0 else { return false }
            guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
                  bounds["Width"] ?? 0 > 50, bounds["Height"] ?? 0 > 50 else { return false }
            return true
        }
        guard !pidWindows.isEmpty else {
            logger.info("播放进程 \(processID) 未找到窗口，回退所有显示器")
            return allDisplayIDs
        }
        // 窗口与屏幕均为 CGWindowList 全局显示坐标，直接判交
        var result = Set<String>()
        for screen in NSScreen.screens {
            let frame = screen.frame
            for win in pidWindows {
                guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                                  width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                if rect.intersects(frame) {
                    result.insert(String(screen.fluxDisplayID))
                    break
                }
            }
        }
        return result
    }
}

/// 辅助进程输出的「正在播放」信息（只取需要的字段）
private struct NowPlayingInfo {
    let playing: Bool
    let processIdentifier: Int
}
