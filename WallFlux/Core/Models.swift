import Foundation

/// 壁纸素材来源类型
enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case video = "video"
    case imageSequence = "imageSequence"

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .system: return "系统动态壁纸"
        case .video: return "视频"
        case .imageSequence: return "图片序列"
        }
    }

    /// 对应的素材类型
    var assetKind: WallpaperAsset.Kind {
        switch self {
        case .system: return .system
        case .video: return .video
        case .imageSequence: return .imageSequence
        }
    }
}

/// 壁纸退出方式
enum ExitMode: String, Codable, CaseIterable, Identifiable {
    case immediate = "immediate"
    case fadeOut = "fadeOut"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .immediate: return "立即停止"
        case .fadeOut: return "渐隐过渡"
        }
    }
}

/// 壁纸配置方式（FR-12）
enum WallpaperConfigMode: String, Codable, CaseIterable, Identifiable {
    case allDisplays = "allDisplays"   // 所有显示器使用同一壁纸
    case perDisplay = "perDisplay"     // 逐显示器单独设置

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allDisplays: return "所有显示器"
        case .perDisplay: return "单独设置"
        }
    }
}

/// 显示器运行状态
enum DisplayState {
    case active
    case idle
    case exiting

    var displayName: String {
        switch self {
        case .active: return "活跃"
        case .idle: return "播放中"
        case .exiting: return "退出中"
        }
    }
}

/// 全局应用配置（UserDefaults + JSON 持久化）
struct AppConfig: Codable, Equatable {
    var idleTimeoutMinutes: Double = 1           // 闲置判定超时 N（分钟）
    var microStepIntervalSeconds: Double = 30    // 微跳间隔 Y（秒）
    var microStepFrameCount: Int = 10            // 微跳帧数 Z
    var exitMode: ExitMode = .immediate          // 退出方式
    /// 鼠标短暂进入宽限期（秒）：鼠标进入闲置显示器后宽限期内继续播放，
    /// 移出或停止移动则保持播放；持续移动满宽限期才退出。0 表示立即退出。
    var briefEntryGraceSeconds: Double = 5
    /// 壁纸配置方式：所有显示器共享 / 逐显示器单独设置
    var wallpaperConfigMode: WallpaperConfigMode = .allDisplays
    /// 所有显示器模式下共享的壁纸类型与素材
    var sharedWallpaperType: WallpaperType = .system
    var sharedWallpaperAssetID: String = "system:.wallpapers/Sequoia Sunrise/Sequoia Sunrise.mov"
    var displayConfigs: [DisplayConfig] = []    // 逐显示器配置（含各显示器帧位置）
}

// 兼容旧版本持久化数据：新增字段缺失时回退默认值
// （合成 Codable 对缺失键直接抛错，不能依赖属性默认值）
extension AppConfig {
    private enum CodingKeys: String, CodingKey {
        case idleTimeoutMinutes, microStepIntervalSeconds, microStepFrameCount, exitMode
        case briefEntryGraceSeconds
        case wallpaperConfigMode, sharedWallpaperType, sharedWallpaperAssetID
        case displayConfigs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idleTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutMinutes) ?? 1
        microStepIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .microStepIntervalSeconds) ?? 30
        microStepFrameCount = try c.decodeIfPresent(Int.self, forKey: .microStepFrameCount) ?? 10
        exitMode = try c.decodeIfPresent(ExitMode.self, forKey: .exitMode) ?? .immediate
        briefEntryGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .briefEntryGraceSeconds) ?? 5
        wallpaperConfigMode = try c.decodeIfPresent(WallpaperConfigMode.self, forKey: .wallpaperConfigMode) ?? .allDisplays
        sharedWallpaperType = try c.decodeIfPresent(WallpaperType.self, forKey: .sharedWallpaperType) ?? .system
        sharedWallpaperAssetID = try c.decodeIfPresent(String.self, forKey: .sharedWallpaperAssetID) ?? "system:.wallpapers/Sequoia Sunrise/Sequoia Sunrise.mov"
        displayConfigs = try c.decodeIfPresent([DisplayConfig].self, forKey: .displayConfigs) ?? []
    }
}

/// 单个显示器的配置，以显示器唯一 ID 标识（热插拔后按 ID 恢复）
struct DisplayConfig: Codable, Equatable, Identifiable {
    /// 显示器唯一标识（NSScreen 的 CGDirectDisplayID，跨版本稳定）
    var displayID: String
    var wallpaperType: WallpaperType = .system  // 壁纸类型
    var wallpaperAssetID: String = ""           // 素材 ID
    var lastFramePosition: Int = 0              // 上次退出帧位置

    var id: String { displayID }
}
