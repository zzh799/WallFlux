import AppKit
import AVFoundation
import Foundation

/// 桌面层级壁纸窗口：视频 / 图片序列渲染与播放控制
///
/// 窗口层级使用 kCGDesktopIconWindowLevel（桌面图标层之上、普通应用窗口之下），
/// 满足 FR-02「壁纸窗口层级在桌面图标之上」；若未来 macOS 版本该层级失效，
/// 可降级为 kCGDesktopWindowLevel（见技术文档 §8 风险缓解）。
final class WallpaperWindow: NSObject {
    private let nsWindow: NSWindow
    private let contentView = WallpaperContentView(frame: .zero)
    private(set) var assetID: String

    // 视频渲染
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var observedItem: AVPlayerItem?

    // 图片序列渲染
    private var renderer: ImageSequenceRenderer?

    private var fps: Double = 30
    /// 素材就绪前暂存的帧位置（视频加载完成后应用）
    private var pendingFrame: Int?

    init(screen: NSScreen, asset: WallpaperAsset) {
        assetID = asset.id

        nsWindow = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        nsWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
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
        nsWindow.orderFrontRegardless()
    }

    /// 切换素材：重建渲染内容
    func reload(asset: WallpaperAsset, screen: NSScreen) {
        teardownContent()
        assetID = asset.id
        pendingFrame = nil
        nsWindow.setFrame(screen.frame, display: true)
        load(asset: asset, screen: screen)
        nsWindow.orderFrontRegardless()
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

    func play() {
        if let queuePlayer {
            queuePlayer.play()
        } else {
            renderer?.startPlayback()
        }
    }

    func pause() {
        if let queuePlayer {
            queuePlayer.pause()
        } else {
            renderer?.stopPlayback()
        }
    }

    /// 向前跳指定帧数并暂停（循环回绕）
    func stepForward(frames: Int) {
        if let queuePlayer {
            let duration = queuePlayer.currentItem?.duration.seconds ?? 0
            guard duration.isFinite, duration > 0 else { return }
            let totalFrames = max(1, Int(duration * fps))
            let current = currentFrame
            seek(toFrame: ((current + frames) % totalFrames + totalFrames) % totalFrames)
        } else {
            renderer?.stepForward(frames: frames)
        }
    }

    func seek(toFrame frame: Int) {
        if let queuePlayer, let item = queuePlayer.currentItem, item.status == .readyToPlay {
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            let totalFrames = max(1, Int(duration * fps))
            let wrapped = ((frame % totalFrames) + totalFrames) % totalFrames
            let seconds = min(Double(wrapped) / fps, max(0, duration - 0.001))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            queuePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pendingFrame = frame
        }
    }

    /// 当前帧序号（视频换算为帧号）
    var currentFrame: Int {
        if let queuePlayer {
            return Int(queuePlayer.currentTime().seconds * fps)
        }
        return renderer?.currentFrame ?? 0
    }

    /// 渐隐后回调；回调时窗口恢复透明度并保持暂停在末帧
    func fadeOut(duration: TimeInterval, completion: @escaping () -> Void) {
        pause()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            nsWindow.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.nsWindow.alphaValue = 1
            completion()
        }
    }

    // MARK: - KVO：视频素材就绪后应用暂存帧

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == #keyPath(AVPlayerItem.status), let item = object as? AVPlayerItem else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if item.status == .readyToPlay {
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
        fps = 30
        // 异步读取视频帧率（同步 API 已弃用）；帧率仅用于帧号换算，默认 30fps 兜底
        Task { @MainActor in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let rate = try? await track.load(.nominalFrameRate),
                  rate > 1 else { return }
            fps = Double(rate)
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
