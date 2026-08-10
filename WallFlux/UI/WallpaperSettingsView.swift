import SwiftUI

/// 壁纸设置页（FR-11 拆分后）：活跃显示器上的壁纸行为 - 微跳模式（FR-03，防烧屏）。
/// 说明文案收纳为行尾「?」帮助按钮（SettingsRow / HelpButton），不占表单行高。
struct WallpaperSettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        Form {
            Section("微跳模式") {
                SettingsRow.slider(title: "微跳间隔",
                                   value: Binding(
                                    get: { configStore.config.microStepIntervalSeconds },
                                    set: { newValue in configStore.update { $0.microStepIntervalSeconds = newValue } }
                                   ),
                                   range: 1...300, unit: "秒", step: 1,
                                   help: "活跃显示器保留壁纸窗口但不播放，每隔微跳间隔向前跳微跳帧数帧，几乎不可察觉地防止烧屏。")

                SettingsRow.stepper(title: "微跳帧数",
                                    value: Binding(
                                     get: { configStore.config.microStepFrameCount },
                                     set: { newValue in configStore.update { $0.microStepFrameCount = newValue } }
                                    ),
                                    range: 1...10, unit: "帧",
                                    help: "每次微跳向前播放的帧数。帧数越多画面变化越明显，与「微跳间隔」共同决定防烧屏节奏。")

                SettingsRow.toggle(title: "全屏应用中不微跳",
                                   isOn: boolBinding(keyPath: \.microStepPauseOnFullscreen),
                                   help: "活跃显示器上存在全屏或最大化的应用窗口时不微跳，避免持续在该窗口之上跳帧；退出全屏后自动恢复。闲置播放不受影响。")
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// AppConfig 布尔字段绑定（写穿 ConfigStore 并触发壁纸/条件刷新）
    private func boolBinding(keyPath: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { configStore.config[keyPath: keyPath] },
            set: { newValue in configStore.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}