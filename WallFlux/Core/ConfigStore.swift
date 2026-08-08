import Combine
import Foundation

/// 配置持久化：UserDefaults + Codable JSON
/// 所有修改立即保存（设置窗口关闭时无需额外保存）
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var config: AppConfig

    /// 配置变更回调（ScreenManager 刷新壁纸、SmartPauseMonitor 重新评估条件）
    private var changeHandlers: [() -> Void] = []

    private let defaults: UserDefaults
    private let key = "WallFlux.appConfig.v1"

    private init() {
        defaults = .standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }
    }

    /// 注册配置变更回调
    func addChangeHandler(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    /// 原子修改并持久化
    func update(_ mutate: (inout AppConfig) -> Void) {
        var newConfig = config
        mutate(&newConfig)
        guard newConfig != config else { return }
        config = newConfig
        persist()
        changeHandlers.forEach { $0() }
    }

    /// 更新单个显示器的配置（不存在则追加）
    func updateDisplayConfig(_ newConfig: DisplayConfig) {
        update { config in
            if let idx = config.displayConfigs.firstIndex(where: { $0.displayID == newConfig.displayID }) {
                config.displayConfigs[idx] = newConfig
            } else {
                config.displayConfigs.append(newConfig)
            }
        }
    }

    // MARK: - 最近使用壁纸（菜单栏面板「最近使用」快捷切换）

    /// 最近使用壁纸记录上限（面板展示最近 3 个，多存几条留作切换历史）
    static let recentWallpapersLimit = 10

    /// 记录一次壁纸使用：相同素材去重置顶、超出上限裁剪（在 update 闭包内调用，与应用原子写入）
    func recordRecentWallpaperUse(_ config: inout AppConfig, type: WallpaperType, assetID: String) {
        guard !assetID.isEmpty else { return }
        config.recentWallpapers.removeAll { $0.assetID == assetID }
        config.recentWallpapers.insert(RecentWallpaperUse(assetID: assetID, type: type, lastUsedAt: Date()), at: 0)
        if config.recentWallpapers.count > Self.recentWallpapersLimit {
            config.recentWallpapers = Array(config.recentWallpapers.prefix(Self.recentWallpapersLimit))
        }
    }

    /// 记录壁纸最近使用（设置页选中壁纸后调用，与应用写入分离）
    func recordRecentWallpaperUse(type: WallpaperType, assetID: String) {
        update { config in
            recordRecentWallpaperUse(&config, type: type, assetID: assetID)
        }
    }

    /// 菜单栏面板「最近使用」快捷切换：把壁纸应用到所有显示器并记录最近使用。
    /// 所有显示模式写入共享壁纸；单独设置模式写入各显示器独立配置（面板无目标显示器选择，
    /// 快捷切换按「所有显示器」语义，保证显示器列表显示与生效一致）；两种模式重置全部帧位置从头播放。
    func quickApplyWallpaper(type: WallpaperType, assetID: String) {
        update { config in
            if config.wallpaperConfigMode == .allDisplays {
                config.sharedWallpaperType = type
                config.sharedWallpaperAssetID = assetID
            } else {
                for idx in config.displayConfigs.indices {
                    config.displayConfigs[idx].wallpaperType = type
                    config.displayConfigs[idx].wallpaperAssetID = assetID
                }
            }
            for idx in config.displayConfigs.indices {
                config.displayConfigs[idx].lastFramePosition = 0
            }
            recordRecentWallpaperUse(&config, type: type, assetID: assetID)
        }
    }

    /// 供调试/测试重置配置
    func reset() {
        config = AppConfig()
        persist()
        changeHandlers.forEach { $0() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
