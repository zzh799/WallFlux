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
