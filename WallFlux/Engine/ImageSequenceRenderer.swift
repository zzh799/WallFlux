import AppKit
import Foundation
import ImageIO

/// 图片序列渲染器
///
/// 通过 ImageIO 按需解码（缩略图尺寸，降低内存占用），
/// 后台队列预解码下一帧，避免播放时卡顿。
/// 支持系统 .heic 动态壁纸与用户导入的图片文件夹。
final class ImageSequenceRenderer {
    /// 图片序列播放帧率
    static let frameRate: Double = 24

    let frameCount: Int
    let displayLayer = CALayer()

    private let source: CGImageSource
    private let maxPixelSize: Int
    private let cache = NSCache<NSNumber, CGImage>()
    private let decodeQueue = DispatchQueue(label: "com.wallflux.imageDecode", qos: .userInitiated)

    private var playbackTimer: Timer?
    private(set) var currentFrame = 0

    init?(url: URL, maxPixelSize: Int) {
        self.maxPixelSize = maxPixelSize
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        self.source = source
        frameCount = count

        displayLayer.contentsGravity = .resizeAspectFill
        displayLayer.masksToBounds = true
        displayLayer.backgroundColor = NSColor.black.cgColor
        cache.countLimit = 2
    }

    // MARK: - 播放控制

    func startPlayback() {
        guard frameCount > 1 else {
            show(frame: 0)
            return
        }
        stopPlayback()
        let timer = Timer(timeInterval: 1.0 / Self.frameRate, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        playbackTimer = timer
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    func stepForward(frames: Int) {
        show(frame: currentFrame + frames)
    }

    func seek(toFrame frame: Int) {
        show(frame: frame)
    }

    // MARK: - 私有

    private func advanceFrame() {
        show(frame: currentFrame + 1)
    }

    private func show(frame: Int) {
        let wrapped = ((frame % frameCount) + frameCount) % frameCount
        currentFrame = wrapped
        if let image = image(at: wrapped) {
            displayLayer.contents = image
        }
        prefetch(next: wrapped + 1)
    }

    /// 当前帧图像（供系统壁纸输出等用途；图片序列已按屏幕像素解码，无需二次处理）
    var currentSnapshotImage: CGImage? { image(at: currentFrame) }

    /// 后台预解码下一帧（NSCache 线程安全）
    private func prefetch(next index: Int) {
        let wrapped = ((index % frameCount) + frameCount) % frameCount
        let key = NSNumber(value: wrapped)
        guard cache.object(forKey: key) == nil else { return }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if let image = self.decode(index: wrapped) {
                self.cache.setObject(image, forKey: key)
            }
        }
    }

    private func image(at index: Int) -> CGImage? {
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) { return cached }
        if let image = decode(index: index) {
            cache.setObject(image, forKey: key)
            return image
        }
        return nil
    }

    private func decode(index: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}
