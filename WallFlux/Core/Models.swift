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
    var idleTimeoutMinutes: Double = 5          // 闲置判定超时 N（分钟）
    var microStepIntervalSeconds: Double = 15   // 微跳间隔 Y（秒）
    var microStepFrameCount: Int = 1            // 微跳帧数 Z
    var exitMode: ExitMode = .fadeOut           // 退出方式
    var displayConfigs: [DisplayConfig] = []    // 逐显示器配置
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
