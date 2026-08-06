import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// 素材缩略图生成（不缓存；内存缓存由 ThumbnailLoader 统一负责）
enum ThumbnailProvider {
    static func thumbnail(for asset: WallpaperAsset, maxPixelSize: CGFloat = 480) -> NSImage? {
        switch asset.renderMode {
        case .video:
            return videoThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        case .imageSequence:
            return imageSequenceThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        }
    }

    private static func videoThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func imageSequenceThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 素材缩略图异步加载器（为素材网格“建立缓存”）：主线程命中缓存即返回，
/// 未命中时后台生成并发布结果；素材被删除时同步清理缓存。
/// 共享实例：缓存跨设置窗口开关保持，同一素材不重复生成缩略图
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    @Published private(set) var images: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "com.wallflux.WallFlux.ThumbnailLoader", qos: .userInitiated)
    private var pending = Set<String>()

    private init() {}

    /// 取缩略图：缓存命中立即返回；未命中触发后台生成，返回 nil（视图先显示占位）
    func thumbnail(for asset: WallpaperAsset, maxPixelSize: CGFloat = 480) -> NSImage? {
        if let image = images[asset.id] { return image }
        schedule(asset, maxPixelSize: maxPixelSize)
        return nil
    }

    /// 预加载一组素材的缩略图（后台生成，不阻塞 UI）
    func preload(_ assets: [WallpaperAsset], maxPixelSize: CGFloat = 480) {
        for asset in assets where images[asset.id] == nil {
            schedule(asset, maxPixelSize: maxPixelSize)
        }
    }

    /// 素材被删除时清理其缓存
    func remove(id: String) {
        images[id] = nil
    }

    private func schedule(_ asset: WallpaperAsset, maxPixelSize: CGFloat) {
        guard !pending.contains(asset.id) else { return }
        pending.insert(asset.id)
        queue.async { [weak self] in
            guard let self else { return }
            let image = ThumbnailProvider.thumbnail(for: asset, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async {
                self.pending.remove(asset.id)
                if let image {
                    self.images[asset.id] = image
                }
            }
        }
    }
}
