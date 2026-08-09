import AppKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// 壁纸引擎：壁纸窗口创建/销毁、播放控制与系统壁纸输出
///
/// feature/system-wallpaper 分支：活跃态不显示壁纸窗口，桌面呈现通过
/// paintDesktopWallpaper 把当前帧输出为系统壁纸（NSWorkspace.setDesktopImageURL）；
/// 窗口仅在闲置循环播放时置顶可见。退出时 restoreOriginalWallpapers 恢复原壁纸。
final class WallpaperEngine {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "WallpaperEngine")
    /// 退出淡出时长（FR-04 默认 0.5 秒）
    static let fadeOutDuration: TimeInterval = 0.5

    private var windows: [String: WallpaperWindow] = [:]

    /// 系统壁纸输出目录：每帧一张 JPEG，文件名带自增序号（同一路径重复设置
    /// 系统不会刷新壁纸内容，必须每次使用新文件；写完后删除上一张）
    private static let desktopDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("WallFlux/Desktop", isDirectory: true)
    /// 壁纸渲染编码队列（串行，避免并发写盘占用过多 CPU）
    private static let desktopQueue = DispatchQueue(label: "com.wallflux.desktopPaint", qos: .userInitiated)
    /// 系统壁纸缩放选项：等比缩放填满（与播放窗口 resizeAspectFill 构图一致）
    private static let desktopImageOptions: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ]

    /// 各屏最近一次落盘的壁纸文件（新壁纸设置成功后删除）
    private var lastDesktopFile: [String: URL] = [:]
    /// 各屏壁纸渲染序号：丢弃过期的渲染结果，防止旧帧覆盖新帧
    /// （微跳与素材重载可能并发触发渲染）
    private var desktopTokens: [String: Int] = [:]
    /// 启动时记录的原始系统壁纸（displayID → URL，退出时恢复）
    private var originalWallpapers: [String: URL] = [:]

    /// 确保指定显示器存在壁纸窗口；素材变化时重建渲染内容
    func ensureWindow(displayID: String, screen: NSScreen, asset: WallpaperAsset) {
        if let window = windows[displayID] {
            if window.assetID != asset.id {
                window.reload(asset: asset, screen: screen)
            }
        } else {
            windows[displayID] = WallpaperWindow(screen: screen, asset: asset)
        }
    }

    func removeWindow(displayID: String) {
        windows.removeValue(forKey: displayID)?.destroy()
    }

    /// 屏幕参数变化时更新窗口位置
    func updateWindowFrame(displayID: String, screen: NSScreen) {
        windows[displayID]?.updateFrame(screen.frame)
    }

    func assetID(for displayID: String) -> String? {
        windows[displayID]?.assetID
    }

    func play(displayID: String) {
        windows[displayID]?.play()
    }

    /// 暂停渲染并隐藏窗口（活跃态桌面由系统壁纸呈现，无壁纸窗口）
    func pause(displayID: String) {
        windows[displayID]?.pause()
    }

    /// 仅恢复窗口置顶可见（不改变播放状态）
    func setOnTop(displayID: String, onTop: Bool) {
        windows[displayID]?.setOnTop(onTop)
    }

    func stepForward(displayID: String, frames: Int) {
        windows[displayID]?.stepForward(frames: frames)
    }

    func seek(displayID: String, toFrame frame: Int) {
        windows[displayID]?.seek(toFrame: frame)
    }

    func currentFrame(displayID: String) -> Int? {
        windows[displayID]?.currentFrame
    }

    func fadeOut(displayID: String, duration: TimeInterval, completion: @escaping () -> Void) {
        windows[displayID]?.fadeOut(duration: duration, completion: completion)
    }

    // MARK: - 系统壁纸输出（feature/system-wallpaper）

    /// 记录启动前各屏原始系统壁纸（须在首次覆盖桌面壁纸前调用），并顺带清理过期壁纸文件
    func recordOriginalWallpapers() {
        sweepStaleDesktopFiles()
        originalWallpapers.removeAll()
        for screen in NSScreen.screens {
            ensureOriginalWallpaper(for: screen)
        }
        logger.info("已记录 \(self.originalWallpapers.count) 个屏幕的原始系统壁纸")
    }

    /// 记录单个屏幕的原始系统壁纸（热插拔新增显示器时补记）
    func ensureOriginalWallpaper(for screen: NSScreen) {
        let id = String(screen.fluxDisplayID)
        guard originalWallpapers[id] == nil,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        originalWallpapers[id] = url
    }

    /// 退出时把各屏系统壁纸恢复为启动前状态。
    /// 仅恢复仍存在的文件（若上次异常退出未恢复、本次记录的"原始"壁纸是
    /// 本应用产物且已被清扫删除，恢复会指向不存在的文件，故跳过让系统自行处理）。
    /// 短暂阻塞让壁纸消息送达窗口服务（进程将随即退出）。
    func restoreOriginalWallpapers() {
        guard !originalWallpapers.isEmpty else { return }
        for (id, url) in originalWallpapers {
            guard let screen = NSScreen.screens.first(where: { String($0.fluxDisplayID) == id }),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.desktopImageOptions)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// 把指定显示器当前帧渲染为图片并直接设置为系统壁纸。
    /// 活跃态（微跳）桌面呈现完全交给系统；素材未就绪时快照挂起，就绪后自动补画。
    func paintDesktopWallpaper(displayID: String, screen: NSScreen) {
        guard let window = windows[displayID] else { return }
        let token = (desktopTokens[displayID] ?? 0) + 1
        desktopTokens[displayID] = token
        window.snapshotImage { [weak self] image in
            guard let self, let image else { return }
            let pixelSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                   height: screen.frame.height * screen.backingScaleFactor)
            Self.desktopQueue.async {
                guard let cropped = Self.coverCrop(image, to: pixelSize) else { return }
                let fileURL = Self.nextDesktopFileURL(displayID: displayID, token: token)
                try? FileManager.default.createDirectory(at: Self.desktopDirectory, withIntermediateDirectories: true)
                guard Self.writeJPEG(cropped, to: fileURL) else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                DispatchQueue.main.async {
                    guard self.desktopTokens[displayID] == token else {
                        // 已有更新的渲染在途，丢弃这份旧帧
                        try? FileManager.default.removeItem(at: fileURL)
                        return
                    }
                    try? NSWorkspace.shared.setDesktopImageURL(fileURL, for: screen, options: Self.desktopImageOptions)
                    if let last = self.lastDesktopFile[displayID], last != fileURL {
                        try? FileManager.default.removeItem(at: last)
                    }
                    self.lastDesktopFile[displayID] = fileURL
                    self.logger.info("已把显示器 \(displayID, privacy: .public) 当前帧输出为系统壁纸")
                }
            }
        }
    }

    // MARK: - 私有

    /// 按 cover 语义（等比放大铺满目标、中心对齐裁剪）绘制目标尺寸图像。
    /// 与播放窗口 AVPlayerLayer .resizeAspectFill 一致，保证静止帧构图与播放画面相同。
    private static func coverCrop(_ image: CGImage, to target: CGSize) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0,
              target.width > 0, target.height > 0 else { return nil }
        let scale = max(target.width / imageSize.width, target.height / imageSize.height)
        let drawnSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let destRect = CGRect(x: (target.width - drawnSize.width) / 2,
                              y: (target.height - drawnSize.height) / 2,
                              width: drawnSize.width, height: drawnSize.height)
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil,
                                  width: Int(target.width.rounded()),
                                  height: Int(target.height.rounded()),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: destRect)
        return ctx.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return false
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        return CGImageDestinationFinalize(dest)
    }

    /// 每帧独占文件名（序号自增）：系统壁纸按 URL 判断变更，重复 URL 不刷新
    private static func nextDesktopFileURL(displayID: String, token: Int) -> URL {
        desktopDirectory.appendingPathComponent("WallFlux-\(displayID)-\(token).jpg")
    }

    /// 清理 24 小时前的壁纸输出文件（微跳持续写入，防止磁盘堆积；
    /// 正在展示的壁纸必然是最新写入的，不会被误删）
    private func sweepStaleDesktopFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.desktopDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
