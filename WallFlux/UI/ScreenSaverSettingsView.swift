import SwiftUI

/// 屏保设置页（FR-11 拆分后）：闲置循环播放（屏保）的触发与退出行为 - 闲置检测（FR-01 / FR-16）+ 退出方式（FR-02）。
/// 说明文案收纳为行尾「?」帮助按钮（SettingsRow / HelpButton），不占表单行高。
struct ScreenSaverSettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared

    var body: some View {
        Form {
            Section("闲置检测") {
                SettingsRow.slider(title: "闲置判定超时",
                                   value: Binding(
                                    get: { configStore.config.idleTimeoutMinutes },
                                    set: { newValue in configStore.update { $0.idleTimeoutMinutes = newValue } }
                                   ),
                                   range: 1...60, unit: "分钟", step: 1,
                                   help: "显示器上超过该时长无鼠标或键盘输入，即判定为闲置并开始循环播放动态壁纸。")

                SettingsRow.toggle(title: "其他应用播放媒体时保持活跃",
                                   isOn: boolBinding(keyPath: \.mediaPlaybackKeepsActive),
                                   help: "系统正在输出声音的应用（播放音乐、视频、直播等，通过系统 CoreAudio 公开 API 检测）所在显示器不进入闲置循环播放，避免壁纸覆盖播放内容；声音停止后恢复。不影响微跳。常见音乐应用（网易云、Spotify、QQ 音乐等）预收集默认忽略名单：真实播放过声音后自动忽略（听歌时壁纸照常循环），可在「媒体应用」页查看名单并逐项管理。")
            }

            Section("退出方式") {
                SettingsRow.slider(title: "短暂进入宽限期",
                                   value: Binding(
                                    get: { configStore.config.briefEntryGraceSeconds },
                                    set: { newValue in configStore.update { $0.briefEntryGraceSeconds = newValue } }
                                   ),
                                   range: 0...60, unit: "秒", step: 1,
                                   help: "鼠标短暂进入播放中的显示器时，壁纸立即让位（暂停并降至窗口之下）；宽限期内鼠标移出或停止移动则恢复置顶播放，持续移动满宽限期才退出。设为 0 秒表示鼠标进入立即退出。")

                SettingsRow.menuPicker(title: "退出方式",
                                       selection: Binding(
                                        get: { configStore.config.exitMode },
                                        set: { newValue in configStore.update { $0.exitMode = newValue } }
                                       ),
                                       help: "显示器从闲置变为活跃时，壁纸以所选方式退出。渐隐过渡默认 0.5 秒淡出。") {
                    ForEach(ExitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
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