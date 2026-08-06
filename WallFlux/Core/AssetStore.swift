import Combine
import Foundation
import os

/// 壁纸素材（系统自带或用户导入）
struct WallpaperAsset: Identifiable, Equatable {
    /// 素材来源类型
    enum Kind: String, Codable {
        case system          // 系统自带壁纸（动态发现，不可删除）
        case video           // 用户导入的视频
        case imageSequence   // 用户导入的图片文件夹
    }

    /// 渲染方式（由文件类型决定）
    enum RenderMode {
        case video
        case imageSequence
    }

    let id: String
    let kind: Kind
    let name: String
    /// 文件或文件夹 URL
    let url: URL

    /// 根据文件扩展名决定渲染方式
    var renderMode: RenderMode {
        let ext = url.pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext) ? .video : .imageSequence
    }

    var kindDisplayName: String {
        switch kind {
        case .system: return "系统动态壁纸"
        case .video: return "视频"
        case .imageSequence: return "图片序列"
        }
    }
}

/// 素材管理：系统壁纸发现、导入、索引与删除
/// 素材存放于 ~/Library/Application Support/WallFlux/Assets/，元数据存 metadata.json
final class AssetStore: ObservableObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "AssetStore")
    static let shared = AssetStore()

    /// 用户导入的素材
    @Published private(set) var importedAssets: [WallpaperAsset] = []
    /// 系统自带壁纸（运行时扫描发现）
    @Published private(set) var systemAssets: [WallpaperAsset] = []

    /// 素材变更回调（ScreenManager 据此刷新壁纸）
    var onChange: (() -> Void)?

    let assetsDirectory: URL
    private let metadataURL: URL
    private var storedAssets: [StoredAsset] = []

    private struct StoredAsset: Codable {
        let id: String
        let kind: WallpaperAsset.Kind
        let name: String
        let relativePath: String
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        assetsDirectory = base.appendingPathComponent("WallFlux/Assets", isDirectory: true)
        metadataURL = assetsDirectory.appendingPathComponent("metadata.json")
    }

    /// 启动：创建素材目录、加载元数据、扫描系统壁纸
    func start() {
        try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        loadMetadata()
        scanSystemWallpapers()
        logger.info("素材扫描完成：系统 \(self.systemAssets.count) 个，导入 \(self.importedAssets.count) 个")
    }

    /// 按 ID 查找素材（系统 + 导入）
    func asset(id: String) -> WallpaperAsset? {
        (systemAssets + importedAssets).first { $0.id == id }
    }

    /// 按类型列出素材
    func assets(for kind: WallpaperAsset.Kind) -> [WallpaperAsset] {
        switch kind {
        case .system:
            return systemAssets
        case .video, .imageSequence:
            return importedAssets.filter { $0.kind == kind }
        }
    }

    /// 某类型的默认素材；无可用素材时回退到第一个系统壁纸
    func fallbackAsset(for kind: WallpaperAsset.Kind) -> WallpaperAsset? {
        assets(for: kind).first ?? systemAssets.first
    }

    // MARK: - 导入

    /// 导入视频文件（复制到素材目录）
    @discardableResult
    func importVideo(from url: URL) throws -> WallpaperAsset {
        try importItem(from: url, kind: .video)
    }

    /// 导入图片文件夹（整体复制到素材目录）
    @discardableResult
    func importImageSequence(from folder: URL) throws -> WallpaperAsset {
        try importItem(from: folder, kind: .imageSequence)
    }

    /// 删除导入的素材（系统素材不可删除）
    func delete(_ asset: WallpaperAsset) {
        guard asset.kind != .system else { return }
        try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent(asset.id))
        storedAssets.removeAll { $0.id == asset.id }
        importedAssets.removeAll { $0.id == asset.id }
        saveMetadata()
        onChange?()
    }

    // MARK: - 私有

    private func importItem(from url: URL, kind: WallpaperAsset.Kind) throws -> WallpaperAsset {
        let id = UUID().uuidString
        let destDir = assetsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destURL)
        let asset = WallpaperAsset(id: id, kind: kind, name: url.lastPathComponent, url: destURL)
        storedAssets.append(StoredAsset(id: id, kind: kind, name: asset.name, relativePath: "\(id)/\(url.lastPathComponent)"))
        saveMetadata()
        importedAssets.append(asset)
        onChange?()
        return asset
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([StoredAsset].self, from: data) else { return }
        storedAssets = decoded
        importedAssets = decoded.compactMap { stored in
            let url = assetsDirectory.appendingPathComponent(stored.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return WallpaperAsset(id: stored.id, kind: stored.kind, name: stored.name, url: url)
        }
    }

    private func saveMetadata() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(storedAssets) {
            try? data.write(to: metadataURL, options: .atomic)
        }
    }

    /// 扫描系统自带壁纸：/System/Library/Desktop Pictures/.wallpapers/ 目录下的动态壁纸视频
    /// （.mov，macOS 15+ 的 Sequoia/Sonoma 系列）。
    /// 不收录其余素材：.madesktop 描述文件只指向 UI 缩略图（单帧小图），根目录 .heic 为
    /// 静态或明暗双帧变体，均无法作为动态壁纸循环播放。
    private func scanSystemWallpapers() {
        let wallpapersDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers", isDirectory: true)
        var videos: [WallpaperAsset] = []

        if let folders = try? FileManager.default.contentsOfDirectory(at: wallpapersDir, includingPropertiesForKeys: nil) {
            for folder in folders where folder.hasDirectoryPath {
                guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
                for file in contents where ["mov", "mp4", "m4v"].contains(file.pathExtension.lowercased()) {
                    let relativePath = ".wallpapers/\(folder.lastPathComponent)/\(file.lastPathComponent)"
                    videos.append(WallpaperAsset(
                        id: "system:\(relativePath)",
                        kind: .system,
                        name: file.deletingPathExtension().lastPathComponent,
                        url: file
                    ))
                }
            }
        }
        videos.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        systemAssets = videos
    }
}
