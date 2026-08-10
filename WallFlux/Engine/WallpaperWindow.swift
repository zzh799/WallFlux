import AppKit
import AVFoundation
import Foundation
import os

/// 壁纸播放窗口：视频 / 图片序列渲染与播放控制
///
/// feature/system-wallpaper 分支：窗口仅在闲置循环播放、退出渐隐期间置顶可见
/// （kCGScreenSaverWindowLevel）；其余时间（活跃微跳）不显示任何壁纸窗口，
/// 桌面呈现由 WallpaperEngine 把当前帧输出为系统壁纸完成（与窗口严格二选一）。
///
/// 视频播放（AVPlayer 管线）依赖窗口可见才会就绪（隐藏窗口不接渲染管线，
/// status 永不 readyToPlay），因此活跃态的帧号推进与壁纸取帧完全基于
/// AVAsset / 自维护帧号计数器，不依赖 AVPlayer 状态；播放器仅负责闲置置顶播放。
final class WallpaperWindow: NSObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "WallpaperWindow")
    private let nsWindow: NSWindow
    private let contentView = WallpaperContentView(frame: .zero)
    private(set) var assetID: String

    // 视频渲染（仅闲置置顶播放时使用；窗口隐藏时管线不启动）
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observedItem: AVPlayerItem?
    private var videoAsset: AVURLAsset?

    // 图片序列渲染
    private var renderer: ImageSequenceRenderer?

    /// 视频帧率（异步从素材读取，未就绪时 30fps 兜底）
    private var fps: Double = 30
    /// 视频总帧数（异步从素材读取，未就绪时为 nil，回绕时退回播放器时长换算）
    private var videoFrameCount: Int?
    /// 活跃态自记帧号（窗口隐藏、播放器未就绪时的帧源；播放中就绪后改由播放时间换算）
    private var steppedFrame = 0
    /// 播放器就绪前暂存的帧位置（就绪后应用到播放器，保证闲置续播位置一致）
    private var pendingFrame: Int?
    /// 当前是否在播放中（播放/暂停/渐隐退出时同步；切换素材后保持原播放状态）
    private var isPlaying = false

    /// 系统壁纸快照的最大像素尺寸（屏幕像素尺寸，限制取帧与编码开销）
    private let snapshotMaxPixelSize: CGSize
    /// 快照取帧队列（后台解码，避免阻塞主线程）
    private static let snapshotQueue = DispatchQueue(label: "com.wallflux.frameSnapshot", qos: .userInitiated)

    init(screen: NSScreen, asset: WallpaperAsset) {
        assetID = asset.id
        snapshotMaxPixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                      height: screen.frame.height * screen.backingScaleFactor)

        nsWindow = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        nsWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
        nsWindow.isOpaque = true
        nsWindow.backgroundColor = .black
        nsWindow.hasShadow = false
        nsWindow.ignoresMouseEvents = true
        nsWindow.isMovable = false
        nsWindow.animationBehavior = .none
        nsWindow.isReleasedWhenClosed = false
        nsWindow.contentView = contentView

        super.init()

        load(asset: asset, screen: screen)
        // 初始保持隐藏：活跃态由系统壁纸呈现，窗口仅闲置播放时显示
    }

    /// 切换素材：重建渲染内容，并在播放状态下恢复播放（否则新内容停留在暂停首帧）
    func reload(asset: WallpaperAsset, screen: NSScreen) {
        teardownContent()
        assetID = asset.id
        pendingFrame = nil
        steppedFrame = 0
        nsWindow.setFrame(screen.frame, display: true)
        load(asset: asset, screen: screen)
        if isPlaying {
            play()
        }
    }

    /// 屏幕参数变化时更新窗口位置
    func updateFrame(_ frame: NSRect) {
        nsWindow.setFrame(frame, display: true)
    }

    func destroy() {
        teardownContent()
        nsWindow.orderOut(nil)
    }

    // MARK: - 播放控制

    /// 播放时窗口置顶可见（屏保层级，覆盖普通窗口与菜单栏）；暂停/活跃时隐藏窗口
    private func applyTopLevel() {
        let target = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        guard nsWindow.level != target else { return }
        nsWindow.level = target
    }

    func play() {
        if let queuePlayer {
            queuePlayer.play()
        } else {
            renderer?.startPlayback()
        }
        isPlaying = true
        applyTopLevel()
        nsWindow.orderFrontRegardless()
    }

    func pause() {
        if let queuePlayer {
            queuePlayer.pause()
        } else {
            renderer?.stopPlayback()
        }
        isPlaying = false
        // 活跃态不再显示窗口：直接隐藏，桌面呈现交给系统壁纸
        nsWindow.orderOut(nil)
    }

    /// 仅恢复窗口置顶可见（不改变播放状态）：宽限期到期恢复顶层让渐隐可见
    func setOnTop(_ onTop: Bool) {
        guard onTop else { return }
        applyTopLevel()
        nsWindow.orderFrontRegardless()
    }

    /// 向前跳指定帧数并暂停（循环回绕）
    func stepForward(frames: Int) {
        if let renderer {
            renderer.stepForward(frames: frames)
            return
        }
        let total = videoTotalFrames()
        guard total > 0 else { return }
        let current = currentFrame
        seek(toFrame: ((current + frames) % total + total) % total)
    }

    func seek(toFrame frame: Int) {
        seek(toFrame: frame, completion: nil)
    }

    private func seek(toFrame frame: Int, completion: (() -> Void)?) {
        var wrapped = frame
        if let queuePlayer, let item = queuePlayer.currentItem, item.status == .readyToPlay {
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            let totalFrames = max(1, Int(duration * fps))
            wrapped = ((frame % totalFrames) + totalFrames) % totalFrames
            steppedFrame = wrapped
            let seconds = min(Double(wrapped) / fps, max(0, duration - 0.001))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            queuePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async {
                    completion?()
                }
            }
        } else {
            steppedFrame = frame
            pendingFrame = frame
            completion?()
        }
    }

    /// 当前帧序号：播放器就绪（闲置播放中）以播放时间为准，否则以自记帧号为准
    var currentFrame: Int {
        if let queuePlayer, let item = queuePlayer.currentItem, item.status == .readyToPlay {
            return Int(queuePlayer.currentTime().seconds * fps)
        }
        if let renderer {
            return renderer.currentFrame
        }
        return steppedFrame
    }

    /// 总帧数（素材已知时用素材帧数，否则回退播放器时长换算；均未知时 0）
    private func videoTotalFrames() -> Int {
        if let count = videoFrameCount, count > 0 { return count }
        if let duration = queuePlayer?.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
            return max(1, Int(duration * fps))
        }
        return 0
    }

    /// 渐隐后回调；回调时窗口恢复透明度并保持暂停在末帧。
    /// 注意：渐隐期间保持窗口置顶可见完成淡出；退出完成后由调用方
    /// pause() 隐藏窗口（活跃态改由系统壁纸呈现）。
    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) {
        // 暂停渲染但不走 pause()，避免提前隐藏窗口
        queuePlayer?.pause()
        renderer?.stopPlayback()
        isPlaying = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            nsWindow.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.nsWindow.alphaValue = 1
            completion()
        }
    }

    /// 截取当前帧图像（供引擎输出为系统壁纸）。
    /// 直接基于 AVAsset 取帧，不依赖 AVPlayer 渲染管线（活跃态窗口隐藏，
    /// 播放器可能从未就绪）；帧位置统一以自记帧号为准。
    func snapshotImage(completion: @escaping (CGImage?) -> Void) {
        if let renderer {
            completion(renderer.currentSnapshotImage)
            return
        }
        guard let asset = videoAsset else {
            completion(nil)
            return
        }
        let frame = currentFrame
        let frameRate = fps
        let maxPixelSize = snapshotMaxPixelSize
        // 预先拷贝 Logger（值类型），避免在 @Sendable 闭包中捕获 self
        let logger = self.logger
        Task { @MainActor in
            // 帧号按真实时长回绕并夹取（时长缺失时落在第 0 帧，无碍）
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let totalFrames = max(1, Int(duration * frameRate))
            let wrapped = ((frame % totalFrames) + totalFrames) % totalFrames
            let seconds = min(Double(wrapped) / frameRate, max(0, duration - 0.001))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            Self.snapshotQueue.async {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                generator.maximumSize = maxPixelSize
                let image = try? generator.copyCGImage(at: time, actualTime: nil)
                DispatchQueue.main.async {
                    if let image {
                        logger.debug("快照第 \(wrapped) 帧（取帧时间 \(seconds)s，总帧数 \(totalFrames)）")
                        completion(image)
                    } else {
                        // 取帧失败时兜底第 0 帧（如素材瞬间不可读），应极少见
                        let gen = AVAssetImageGenerator(asset: asset)
                        gen.appliesPreferredTrackTransform = true
                        gen.maximumSize = maxPixelSize
                        let fallback = try? gen.copyCGImage(at: .zero, actualTime: nil)
                        completion(fallback)
                    }
                }
            }
        }
    }

    // MARK: - KVO：播放器就绪后应用暂存帧

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(AVPlayerItem.status), let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if item.status == .readyToPlay {
            logger.debug("播放器就绪（窗口可见后渲染管线启动）")
            if let frame = pendingFrame {
                pendingFrame = nil
                seek(toFrame: frame)
            }
        }
    }

    // MARK: - 私有

    private func load(asset: WallpaperAsset, screen: NSScreen) {
        switch asset.renderMode {
        case .video:
            setupVideo(url: asset.url)
        case .imageSequence:
            setupImageSequence(url: asset.url, screen: screen)
        }
    }

    private func setupVideo(url: URL) {
        let asset = AVURLAsset(url: url)
        videoAsset = asset
        fps = 30
        // 帧率与总帧数从素材异步读取（同步 API 已弃用）；仅用于帧号换算与回绕
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let rate = (try? await track.load(.nominalFrameRate)) ?? 30
            guard rate > 1 else { return }
            fps = Double(rate)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            if duration.isFinite, duration > 0 {
                videoFrameCount = max(1, Int(duration * Double(rate)))
            }
        }

        let item = AVPlayerItem(asset: asset)
        item.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.new], context: nil)
        observedItem = item

        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        contentView.setPlayerLayer(layer)
        player.pause()
    }

    private func setupImageSequence(url: URL, screen: NSScreen) {
        let pixelSize = max(screen.frame.width * screen.backingScaleFactor,
                            screen.frame.height * screen.backingScaleFactor)
        guard let renderer = ImageSequenceRenderer(url: url, maxPixelSize: Int(pixelSize.rounded())) else { return }
        self.renderer = renderer
        contentView.setImageLayer(renderer.displayLayer)
        renderer.seek(toFrame: 0)
    }

    private func teardownContent() {
        queuePlayer?.pause()
        observedItem?.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status))
        observedItem = nil
        looper = nil
        queuePlayer = nil
        videoAsset = nil
        videoFrameCount = nil
        renderer?.stopPlayback()
        renderer = nil
        contentView.clear()
    }
}

/// 窗口内容视图：承载 AVPlayerLayer 或图片序列 CALayer，黑色兜底
private final class WallpaperContentView: NSView {
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    func setPlayerLayer(_ layer: AVPlayerLayer) {
        clear()
        playerLayer = layer
        self.layer?.addSublayer(layer)
        layer.frame = bounds
    }

    func setImageLayer(_ layer: CALayer) {
        clear()
        imageLayer = layer
        self.layer?.addSublayer(layer)
        layer.frame = bounds
    }

    func clear() {
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        imageLayer?.removeFromSuperlayer()
        imageLayer = nil
    }

    override func layout() {
        super.layout()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        imageLayer?.frame = bounds
    }
}
