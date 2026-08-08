import Foundation

/// 壁纸素材来源类型
enum WallpaperType: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case screenSaver = "screenSaver"
    case video = "video"
    case imageSequence = "imageSequence"

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .system: return "系统动态壁纸"
        case .screenSaver: return "系统屏保"
        case .video: return "视频"
        case .imageSequence: return "图片序列"
        }
    }

    /// 对应的素材类型
    var assetKind: WallpaperAsset.Kind {
        switch self {
        case .system: return .system
        case .screenSaver: return .screenSaver
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

/// 智能暂停原因（设计文档 §2.2 暂停源模型）
/// 任一启用条件命中即完全暂停（停播放 + 停微跳），无降频中间态。
/// 全部为全局条件，命中作用于所有屏。全屏应用不属于智能暂停：
/// 它作为微跳模式的独立行为存在（见 `microStepPauseOnFullscreen`）。
enum SmartPauseReason: String, CaseIterable, Identifiable {
    case systemSleep = "systemSleep"
    case displaySleep = "displaySleep"
    case lowPowerMode = "lowPowerMode"
    case batteryPower = "batteryPower"
    case lowBattery = "lowBattery"

    var id: String { rawValue }

    /// 中文显示名
    var displayName: String {
        switch self {
        case .systemSleep: return "系统睡眠"
        case .displaySleep: return "显示器睡眠"
        case .lowPowerMode: return "低电量模式"
        case .batteryPower: return "电池供电"
        case .lowBattery: return "低电量"
        }
    }

    /// 解决指引（面板提示用）
    var guidance: String {
        switch self {
        case .systemSleep: return "系统唤醒后自动恢复"
        case .displaySleep: return "唤醒显示器后自动恢复"
        case .lowPowerMode: return "关闭系统低电量模式后恢复"
        case .batteryPower: return "接通电源后恢复"
        case .lowBattery: return "充电至阈值以上后恢复"
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

    // 智能暂停（设计文档 §3）：总开关 OFF 时各条件开关保留配置但不生效
    var smartPauseEnabled: Bool = true          // 智能暂停总开关
    var pauseOnSleep: Bool = true               // 系统睡眠
    var pauseOnDisplaySleep: Bool = true        // 显示器睡眠
    var pauseOnLowPowerMode: Bool = true        // 低电量模式
    var pauseOnBattery: Bool = true             // 电池供电
    var pauseOnLowBattery: Bool = true          // 低电量阈值
    var lowBatteryThresholdPercent: Double = 40 // 低电量阈值（5...50）
    /// 全屏应用暂停微跳（微跳模式）：活跃屏存在全屏/最大化应用窗口时不微跳；
    /// 闲置屏不受影响，照常循环播放（屏保优先）。不属于智能暂停。
    var microStepPauseOnFullscreen: Bool = true
    /// 其他应用播放媒体（视频/直播/音乐等）时保持活跃：命中屏不进入闲置循环播放，
    /// 避免壁纸覆盖播放内容；媒体暂停/结束后恢复。不属于智能暂停（不暂停微跳）。
    var mediaPlaybackKeepsActive: Bool = true
    /// 媒体保持活跃时忽略的应用（身份键集合）：被忽略的应用即使正在出声也不命中，
    /// 所在屏可正常进入闲置循环播放。发现历史照常记录。
    var ignoredAudioAppKeys: [String] = []
    /// 用户手动取消了忽略的白名单键：这些键不再自动忽略
    ///（白名单应用出声时自动追加进忽略名单）
    var mediaWhitelistUserExcludedKeys: [String] = []
    /// 本机播放过声音的应用（CoreAudio 进程级检测累积记录，设置「媒体应用」页展示）
    var audioAppHistory: [AudioAppRecord] = []
}

/// 单个应用的音频播放记录（发现历史与「正在播放」列表共用）
struct AudioAppRecord: Codable, Equatable, Identifiable {
    /// 稳定身份键：bundle ID（无 bundle ID 的进程为 "proc:<进程名>"）
    var key: String
    var bundleID: String?
    /// 应用名（NSRunningApplication 本地化名称，进程退出后以历史为准）
    var name: String
    /// 最近一次播放声音的时间
    var lastPlayedAt: Date

    var id: String { key }
}

// 兼容旧版本持久化数据：新增字段缺失时回退默认值
// （合成 Codable 对缺失键直接抛错，不能依赖属性默认值）
extension AppConfig {
    private enum CodingKeys: String, CodingKey {
        case idleTimeoutMinutes, microStepIntervalSeconds, microStepFrameCount, exitMode
        case briefEntryGraceSeconds
        case wallpaperConfigMode, sharedWallpaperType, sharedWallpaperAssetID
        case displayConfigs
        case smartPauseEnabled, pauseOnSleep, pauseOnDisplaySleep, pauseOnLowPowerMode
        // 存储键沿用旧名 "pauseOnFullscreen"，兼容旧版本持久化数据
        case pauseOnBattery, pauseOnLowBattery, lowBatteryThresholdPercent,
             microStepPauseOnFullscreen = "pauseOnFullscreen", mediaPlaybackKeepsActive,
             ignoredAudioAppKeys, mediaWhitelistUserExcludedKeys, audioAppHistory
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
        // 智能暂停（旧版本数据缺省时全部回退默认值）
        smartPauseEnabled = try c.decodeIfPresent(Bool.self, forKey: .smartPauseEnabled) ?? true
        pauseOnSleep = try c.decodeIfPresent(Bool.self, forKey: .pauseOnSleep) ?? true
        pauseOnDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .pauseOnDisplaySleep) ?? true
        pauseOnLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowPowerMode) ?? true
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? true
        pauseOnLowBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowBattery) ?? true
        lowBatteryThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .lowBatteryThresholdPercent) ?? 40
        microStepPauseOnFullscreen = try c.decodeIfPresent(Bool.self, forKey: .microStepPauseOnFullscreen) ?? true
        mediaPlaybackKeepsActive = try c.decodeIfPresent(Bool.self, forKey: .mediaPlaybackKeepsActive) ?? true
        // 媒体应用忽略名单、白名单用户排除键与发现历史（旧版本数据缺省时回退默认）
        ignoredAudioAppKeys = try c.decodeIfPresent([String].self, forKey: .ignoredAudioAppKeys) ?? []
        mediaWhitelistUserExcludedKeys = try c.decodeIfPresent([String].self, forKey: .mediaWhitelistUserExcludedKeys) ?? []
        audioAppHistory = try c.decodeIfPresent([AudioAppRecord].self, forKey: .audioAppHistory) ?? []
    }
}

/// 常见音乐应用白名单（国内外预收集）
///
/// 白名单应用默认忽略：即使正在出声也不阻止所在显示器进入闲置循环播放。
/// 纯音乐/音频应用没有需要保护的视觉内容（壁纸不会盖住任何画面），听歌时壁纸照常循环；
/// 视频/直播类应用（浏览器、视频网站、直播平台）不在白名单内，播放时保持活跃以保护画面。
/// 匹配键为 bundle ID；一个应用收录全部已知的历史 ID 变体（命中任一即忽略，
/// 多余的 ID 不产生副作用）。白名单不在启动时预置：应用真实出声时自动加入
/// 忽略名单（用户手动关闭过的键除外，见 `mediaWhitelistUserExcludedKeys`），
/// 名单本身可在「媒体应用」页只读查看。
struct MediaAppWhitelist {
    /// 应用所属区域（国内外分组展示）
    enum Region: String, CaseIterable, Identifiable {
        case domestic = "国内"
        case international = "国际"

        var id: String { rawValue }
    }

    /// 白名单条目
    struct Entry: Identifiable {
        let name: String
        let region: Region
        /// 全部已知 bundle ID（含历史版本变体），命中任一即忽略
        let bundleIDs: [String]

        /// 列表行标识：首个 bundle ID
        var id: String { bundleIDs[0] }
    }

    /// 国内常见音乐应用
    static let domestic: [Entry] = [
        Entry(name: "网易云音乐", region: .domestic,
              bundleIDs: ["com.163.music", "com.netease.music", "com.netease.cloudmusic"]),
        Entry(name: "QQ 音乐", region: .domestic,
              bundleIDs: ["com.tencent.QQMusicMac", "com.tencent.QQMusic"]),
        Entry(name: "酷狗音乐", region: .domestic,
              bundleIDs: ["com.kugou", "com.kugou.mac", "com.kugou.kugou1002"]),
        Entry(name: "酷我音乐", region: .domestic,
              bundleIDs: ["com.kuwo.music", "com.kuwo", "com.dragongame.KuWoMusic"]),
        Entry(name: "咪咕音乐", region: .domestic,
              bundleIDs: ["com.migu.music"]),
        Entry(name: "喜马拉雅", region: .domestic,
              bundleIDs: ["com.ximalaya.ting", "com.ximalaya.mac"]),
        Entry(name: "蜻蜓 FM", region: .domestic,
              bundleIDs: ["com.qingting.ting"]),
        Entry(name: "荔枝 FM", region: .domestic,
              bundleIDs: ["com.lizhi.fm"]),
    ]

    /// 国际常见音乐应用
    static let international: [Entry] = [
        Entry(name: "Apple Music", region: .international, bundleIDs: ["com.apple.Music"]),
        Entry(name: "iTunes", region: .international, bundleIDs: ["com.apple.iTunes"]),
        Entry(name: "Spotify", region: .international, bundleIDs: ["com.spotify.client"]),
        Entry(name: "YouTube Music", region: .international, bundleIDs: ["com.google.YouTubeMusic"]),
        Entry(name: "TIDAL", region: .international, bundleIDs: ["com.tidal.desktop", "com.tidal"]),
        Entry(name: "Deezer", region: .international, bundleIDs: ["com.deezer.app"]),
        Entry(name: "Amazon Music", region: .international, bundleIDs: ["com.amazon.music"]),
        Entry(name: "Pandora", region: .international, bundleIDs: ["com.pandora.desktop", "com.pandora.radio"]),
        Entry(name: "SoundCloud", region: .international, bundleIDs: ["com.soundcloud.desktop"]),
        Entry(name: "Qobuz", region: .international, bundleIDs: ["com.qobuz.mac"]),
        Entry(name: "Audible", region: .international, bundleIDs: ["com.audible.mac"]),
        Entry(name: "VOX", region: .international, bundleIDs: ["com.coppertino.Vox"]),
        Entry(name: "Swinsian", region: .international, bundleIDs: ["com.swinsian"]),
        Entry(name: "Audirvana", region: .international, bundleIDs: ["com.audirvana.audirvana"]),
        Entry(name: "foobar2000", region: .international, bundleIDs: ["com.foobar2000mac.foobar2000"]),
        Entry(name: "KKBOX", region: .international, bundleIDs: ["com.kkbox.mac"]),
    ]

    static var all: [Entry] { domestic + international }

    /// 全部可匹配的身份键（bundle ID 集合，含历史变体）
    static var allKeys: [String] { all.flatMap(\.bundleIDs) }
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
