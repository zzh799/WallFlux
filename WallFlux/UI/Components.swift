import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// 素材缩略图生成（按素材 ID 缓存）
enum ThumbnailProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for asset: WallpaperAsset, maxPixelSize: CGFloat = 480) -> NSImage? {
        if let cached = cache.object(forKey: asset.id as NSString) { return cached }
        let image: NSImage?
        switch asset.renderMode {
        case .video:
            image = videoThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        case .imageSequence:
            image = imageSequenceThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        }
        if let image {
            cache.setObject(image, forKey: asset.id as NSString)
        }
        return image
    }

    static func clearCache() {
        cache.removeAllObjects()
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
