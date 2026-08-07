import Combine
import Foundation
import os

/// 壁纸素材（系统自带或用户导入）
struct WallpaperAsset: Identifiable, Equatable {
    /// 素材来源类型
    enum Kind: String, Codable {
        case system          // 系统自带壁纸（动态发现，不可删除）
        case screenSaver     // 系统 Aerial 屏保视频（动态发现，不可删除，系统目录只读引用）
        case video           // 用户导入的视频（含从 Aerial CDN 下载到素材库的视频）
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

    /// 是否可删除（仅用户素材可删除；系统素材与系统屏保素材只读）
    var isDeletable: Bool {
        kind == .video || kind == .imageSequence
    }

    var kindDisplayName: String {
        switch kind {
        case .system: return "系统动态壁纸"
        case .screenSaver: return "系统屏保"
        case .video: return "视频"
        case .imageSequence: return "图片序列"
        }
    }
}

// MARK: - 系统 Aerial 屏保目录模型（对应系统 entries.json）

/// 系统 Aerial 屏保资产目录条目
struct AerialCatalogItem: Codable, Identifiable, Equatable {
    let id: String                       // 资产 UUID（与系统下载目录中的文件名一致）
    let accessibilityLabel: String?      // 英文显示名
    let localizedNameKey: String?        // 本地化键（经系统本地化表解析）
    let previewImage: String?            // 官方预览图 URL
    let downloadURL: String?             // 4K SDR 240FPS 下载地址（Apple CDN）
    let showInTopLevel: Bool?
    let categories: [String]?
    let subcategories: [String]?

    enum CodingKeys: String, CodingKey {
        case id, accessibilityLabel, localizedNameKey, previewImage
        case downloadURL = "url-4K-SDR-240FPS"
        case showInTopLevel, categories, subcategories
    }
}

/// 系统 Aerial 屏保资产分类（分类筛选用）
struct AerialCatalogCategory: Codable, Identifiable, Equatable {
    let id: String
    let localizedNameKey: String?
    let subcategories: [AerialCatalogSubcategory]?
}

struct AerialCatalogSubcategory: Codable, Identifiable, Equatable {
    let id: String
    let localizedNameKey: String?
    let representativeAssetID: String?
}

/// entries.json 顶层结构
struct AerialCatalog: Codable {
    let assets: [AerialCatalogItem]
    let categories: [AerialCatalogCategory]?
}

/// 素材管理：系统壁纸发现、系统 Aerial 屏保扫描/下载、导入、索引与删除
/// 素材存放于 ~/Library/Application Support/WallFlux/Assets/，元数据存 metadata.json
final class AssetStore: ObservableObject {
    private let logger = Logger(subsystem: "com.wallflux.WallFlux", category: "AssetStore")
    static let shared = AssetStore()

    /// 用户导入的素材
    @Published private(set) var importedAssets: [WallpaperAsset] = []
    /// 系统自带壁纸（运行时扫描发现）
    @Published private(set) var systemAssets: [WallpaperAsset] = []
    /// 系统 Aerial 屏保已下载视频（运行时扫描发现，系统目录只读引用，不复制）
    @Published private(set) var screenSaverAssets: [WallpaperAsset] = []
    /// 系统 Aerial 屏保资产目录（137 个，未下载的也可展示）
    @Published private(set) var aerialCatalog: [AerialCatalogItem] = []
    /// 系统 Aerial 屏保资产分类
    @Published private(set) var aerialCategories: [AerialCatalogCategory] = []
    /// Aerial 素材下载进度（catalogID -> 0...1；下载完成/取消后移除）
    @Published private(set) var downloadProgress: [String: Double] = [:]
    /// Aerial 素材下载失败原因（catalogID -> 错误文案）
    @Published private(set) var downloadErrors: [String: String] = [:]

    /// 素材变更回调（ScreenManager 据此刷新壁纸）
    var onChange: (() -> Void)?

    let assetsDirectory: URL
    private let metadataURL: URL
    private var storedAssets: [StoredAsset] = []
    /// 素材库内 Aerial 下载资产：catalogID -> 素材 id（用于按目录项反查）
    private var aerialLibraryIDs: [String: String] = [:]
    /// Aerial 本地化字符串表（catalogID 的 localizedNameKey → 当前系统语言文案）
    private var screensaverStrings: [String: String] = [:]
    /// 进行中的下载任务与进度观察
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    /// 系统 Aerial 屏保目录（idleassetsd 管理，root:wheel 拥有，只读）
    static let screenSaverDirectory = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)
    /// 系统内置 Aerial 清单（离线兜底，未下载任何视频也可读取）
    private static let systemCatalogURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/TVIdleServices.framework/Versions/A/Resources/entries.json")
    private static let customerCatalogURL = screenSaverDirectory.appendingPathComponent("entries.json")
    /// 系统本地化字符串表候选（框架内置 loctable / Customer 目录 loctable）
    private static let loctableCandidates = [
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/TVIdleServices.framework/Versions/A/Resources/TVIdleScreenStrings.bundle/Localizable.nocache.loctable"),
        screenSaverDirectory.appendingPathComponent("TVIdleScreenStrings.bundle/Localizable.nocache.loctable"),
    ]

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

    /// 启动：创建素材目录、加载元数据、扫描系统壁纸与系统屏保视频
    func start() {
        try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        loadMetadata()
        scanSystemWallpapers()
        scanScreenAerialAssets()
        logger.info("素材扫描完成：系统 \(self.systemAssets.count) 个，屏保 \(self.screenSaverAssets.count) 个，导入 \(self.importedAssets.count) 个")
    }

    /// 按 ID 查找素材（系统 + 系统屏保 + 导入）
    func asset(id: String) -> WallpaperAsset? {
        (systemAssets + screenSaverAssets + importedAssets).first { $0.id == id }
    }

    /// 按类型列出素材
    func assets(for kind: WallpaperAsset.Kind) -> [WallpaperAsset] {
        switch kind {
        case .system:
            return systemAssets
        case .screenSaver:
            return screenSaverAssets
        case .video, .imageSequence:
            return importedAssets.filter { $0.kind == kind }
        }
    }

    /// 某类型的默认素材；无可用素材时回退到第一个系统壁纸
    func fallbackAsset(for kind: WallpaperAsset.Kind) -> WallpaperAsset? {
        assets(for: kind).first ?? systemAssets.first
    }

    // MARK: - 系统 Aerial 屏保（扫描 / 目录 / 下载）

    /// 扫描系统 Aerial 屏保目录：/Library/Application Support/com.apple.idleassetsd/Customer/
    /// 下各分辨率子目录（4KSDR240FPS 等）的已下载视频，文件名即资产 UUID。
    /// 系统目录 root 拥有、只读：WallFlux 只引用不复制，与系统屏保共用同一份文件。
    func scanScreenAerialAssets() {
        loadAerialCatalog()
        loadScreensaverStrings()

        var found: [WallpaperAsset] = []
        var seenIDs = Set<String>()
        if let formatDirs = try? FileManager.default.contentsOfDirectory(at: Self.screenSaverDirectory, includingPropertiesForKeys: nil) {
            for dir in formatDirs where dir.hasDirectoryPath {
                guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for file in files where ["mov", "mp4", "m4v"].contains(file.pathExtension.lowercased()) {
                    let itemID = file.deletingPathExtension().lastPathComponent
                    guard !seenIDs.contains(itemID) else { continue }
                    seenIDs.insert(itemID)
                    let name = aerialDisplayName(forID: itemID) ?? file.deletingPathExtension().lastPathComponent
                    found.append(WallpaperAsset(id: "screensaver:\(itemID)", kind: .screenSaver, name: name, url: file))
                }
            }
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        screenSaverAssets = found
    }

    /// 按目录项 ID 查找可用素材（优先系统已下载引用，其次素材库下载）
    func aerialAsset(for itemID: String) -> WallpaperAsset? {
        if let asset = screenSaverAssets.first(where: { $0.id == "screensaver:\(itemID)" }) {
            return asset
        }
        if let assetID = aerialLibraryIDs[itemID] {
            return importedAssets.first { $0.id == assetID }
        }
        return nil
    }

    /// 目录项是否已被系统下载（系统目录中存在同名视频）
    func isSystemDownloaded(_ itemID: String) -> Bool {
        screenSaverAssets.contains { $0.id == "screensaver:\(itemID)" }
    }

    /// 目录项显示名：本地化名 → 英文名 → UUID 前缀
    func aerialDisplayName(for item: AerialCatalogItem) -> String {
        if let key = item.localizedNameKey, let name = screensaverStrings[key], !name.isEmpty {
            return name
        }
        if let label = item.accessibilityLabel, !label.isEmpty {
            return label
        }
        return String(item.id.prefix(8))
    }

    /// 分类显示名（本地化，失败回退键名）
    func aerialCategoryDisplayName(_ category: AerialCatalogCategory) -> String {
        if let key = category.localizedNameKey, let name = screensaverStrings[key], !name.isEmpty {
            return name
        }
        return category.localizedNameKey ?? "未命名分类"
    }

    /// 目录项所属分类
    func aerialCategory(for item: AerialCatalogItem) -> AerialCatalogCategory? {
        guard let categoryID = item.categories?.first else { return nil }
        return aerialCategories.first { $0.id == categoryID }
    }

    /// 目录项所属子分类显示名（如「Sonoma」「Sequoia」）
    func aerialSubcategoryName(for item: AerialCatalogItem) -> String? {
        guard let subID = item.subcategories?.first else { return nil }
        for category in aerialCategories {
            if let sub = category.subcategories?.first(where: { $0.id == subID }),
               let key = sub.localizedNameKey,
               let name = screensaverStrings[key], !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// 下载 Aerial 素材到 WallFlux 素材库（作为视频素材，可删除）
    /// 系统已下载或正在下载的目录项会被忽略。
    func downloadAerialItem(_ item: AerialCatalogItem) {
        let itemID = item.id
        guard downloadProgress[itemID] == nil else { return } // 正在下载
        guard aerialAsset(for: itemID) == nil else { return } // 已有可用素材
        guard let urlString = item.downloadURL, let url = URL(string: urlString) else {
            downloadErrors[itemID] = "下载地址无效"
            return
        }

        let destDir = assetsDirectory.appendingPathComponent("aerial-\(itemID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let fileName = "\(safeFileName(aerialDisplayName(for: item))).mov"
        let destURL = destDir.appendingPathComponent(fileName)

        downloadProgress[itemID] = 0
        downloadErrors[itemID] = nil

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                self?.finishAerialDownload(itemID: itemID, tempURL: tempURL, destURL: destURL, error: error)
            }
        }
        let observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard let self, self.downloadProgress[itemID] != nil else { return }
                self.downloadProgress[itemID] = progress.fractionCompleted
            }
        }
        activeDownloads[itemID] = task
        progressObservations[itemID] = observation
        task.resume()
        logger.info("开始下载 Aerial 素材 \(itemID, privacy: .public)")
    }

    /// 取消进行中的 Aerial 下载
    func cancelAerialDownload(_ itemID: String) {
        activeDownloads[itemID]?.cancel()
        activeDownloads[itemID] = nil
        progressObservations[itemID]?.invalidate()
        progressObservations[itemID] = nil
        downloadProgress[itemID] = nil
        try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent("aerial-\(itemID)", isDirectory: true))
    }

    /// 删除导入的素材（系统素材与系统屏保素材只读，不可删除）
    func delete(_ asset: WallpaperAsset) {
        guard asset.isDeletable else { return }
        try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent(asset.id))
        storedAssets.removeAll { $0.id == asset.id }
        importedAssets.removeAll { $0.id == asset.id }
        aerialLibraryIDs = aerialLibraryIDs.filter { $0.value != asset.id }
        saveMetadata()
        onChange?()
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

    /// 下载完成收尾：移动临时文件到素材库并登记
    private func finishAerialDownload(itemID: String, tempURL: URL?, destURL: URL, error: Error?) {
        progressObservations[itemID]?.invalidate()
        progressObservations[itemID] = nil
        activeDownloads[itemID] = nil
        defer { downloadProgress[itemID] = nil }

        if let error {
            downloadErrors[itemID] = "下载失败：\(error.localizedDescription)"
            try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent("aerial-\(itemID)", isDirectory: true))
            logger.error("Aerial 素材下载失败 \(itemID, privacy: .public): \(error.localizedDescription)")
            return
        }
        guard let tempURL else {
            downloadErrors[itemID] = "下载失败：未获得文件"
            return
        }
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch {
            downloadErrors[itemID] = "保存失败：\(error.localizedDescription)"
            return
        }

        let asset = WallpaperAsset(id: "aerial-\(itemID)", kind: .video, name: destURL.deletingPathExtension().lastPathComponent, url: destURL)
        storedAssets.append(StoredAsset(id: asset.id, kind: .video, name: asset.name, relativePath: "aerial-\(itemID)/\(destURL.lastPathComponent)"))
        aerialLibraryIDs[itemID] = asset.id
        importedAssets.append(asset)
        saveMetadata()
        onChange?()
        logger.info("Aerial 素材下载完成 \(itemID, privacy: .public)")
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
        // 还原 Aerial 下载映射（素材 id 为 "aerial-<catalogID>"）
        for stored in storedAssets where stored.id.hasPrefix("aerial-") {
            aerialLibraryIDs[String(stored.id.dropFirst("aerial-".count))] = stored.id
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

    /// 读取系统 Aerial 目录清单：优先 Customer/entries.json（与实际下载对账），
    /// 其次系统内置清单（离线兜底，未下载过任何视频也可读）。
    private func loadAerialCatalog() {
        let candidates = [Self.customerCatalogURL, Self.systemCatalogURL]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let catalog = try? JSONDecoder().decode(AerialCatalog.self, from: data) else { continue }
            aerialCatalog = catalog.assets
            aerialCategories = catalog.categories ?? []
            logger.info("Aerial 目录加载成功：\(catalog.assets.count) 个资产（\(url.lastPathComponent)）")
            return
        }
        aerialCatalog = []
        aerialCategories = []
        logger.warning("Aerial 目录加载失败：Customer 与系统内置清单均不可读")
    }

    /// 读取系统 Aerial 本地化字符串表（当前系统语言；框架内置 loctable 离线可用）
    private func loadScreensaverStrings() {
        for url in Self.loctableCandidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let raw = plist as? [String: Any] else { continue }
            // 两层字典需逐层桥接（嵌套 NSDictionary 无法一次条件转型）
            let loctable = raw.compactMapValues { $0 as? [String: String] }
            guard let table = Self.pickLocalizedTable(loctable) else { continue }
            screensaverStrings = table
            return
        }
        screensaverStrings = [:]
        logger.warning("Aerial 本地化表加载失败")
    }

    /// 从 loctable（语言代码 → 字符串表）中挑选当前系统语言对应的表
    private static func pickLocalizedTable(_ loctable: [String: [String: String]]) -> [String: String]? {
        let languages = Locale.preferredLanguages
        for lang in languages {
            if let table = loctable[lang] { return table }
        }
        for lang in languages {
            let prefix = String(lang.prefix(2))
            if prefix == "zh" {
                // 简体中文优先（loctable 键为 zh_CN / zh_HK / zh_TW）
                for key in ["zh_CN", "zh_HK", "zh_TW"] where loctable[key] != nil {
                    return loctable[key]
                }
            } else if let table = loctable[prefix] {
                return table
            }
        }
        return loctable["en"]
    }

    /// 目录项显示名（按 ID 反查目录；未收录时返回 nil）
    private func aerialDisplayName(forID itemID: String) -> String? {
        guard let item = aerialCatalog.first(where: { $0.id == itemID }) else { return nil }
        return aerialDisplayName(for: item)
    }

    /// 文件名安全化（去除路径分隔符等非法字符）
    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:?%*|\"<>\\")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Aerial" : cleaned
    }
}
