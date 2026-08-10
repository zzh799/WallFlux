import SwiftUI

/// 全局设置页（FR-11 拆分后）：保留与显示器播放无关的应用级设置 - 智能暂停（FR-14）+ 启动（FR-15）。
/// 说明文案收纳为行尾「?」帮助按钮（SettingsRow / HelpButton），不占表单行高。
struct GeneralSettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var smartPauseMonitor = CoreManager.shared.smartPauseMonitor

    var body: some View {
        Form {
            Section("智能暂停") {
                SettingsRow.toggle(title: "启用智能暂停",
                                   isOn: boolBinding(keyPath: \.smartPauseEnabled),
                                   help: "开启后，任一启用条件命中时完全暂停所有显示器的壁纸播放与微跳；关闭则回归纯手动控制，各条件开关保留配置但不生效。")

                if configStore.config.smartPauseEnabled {
                    SettingsRow.toggle(title: "系统睡眠",
                                       isOn: boolBinding(keyPath: \.pauseOnSleep),
                                       help: "macOS 进入睡眠时暂停所有壁纸播放与微跳；唤醒后恢复。")
                    SettingsRow.toggle(title: "显示器睡眠",
                                       isOn: boolBinding(keyPath: \.pauseOnDisplaySleep),
                                       help: "任一台显示器进入睡眠时暂停该显示器的壁纸播放与微跳；唤醒后恢复。")
                    SettingsRow.toggle(title: "低电量模式",
                                       isOn: boolBinding(keyPath: \.pauseOnLowPowerMode),
                                       help: "系统开启低电量模式时暂停所有壁纸播放与微跳；关闭低电量模式后恢复。")
                    SettingsRow.toggle(title: "电池供电",
                                       isOn: boolBinding(keyPath: \.pauseOnBattery),
                                       help: "拔掉电源、切换到电池供电时暂停所有壁纸播放与微跳；插电后恢复。")
                    SettingsRow.toggle(title: "低电量",
                                       isOn: boolBinding(keyPath: \.pauseOnLowBattery),
                                       help: "电量低于设定阈值时暂停所有壁纸播放与微跳；充至阈值 +5% 后恢复。")

                    if configStore.config.pauseOnLowBattery {
                        SettingsRow.slider(title: "低电量阈值",
                                           value: Binding(
                                            get: { configStore.config.lowBatteryThresholdPercent },
                                            set: { newValue in configStore.update { $0.lowBatteryThresholdPercent = newValue } }
                                           ),
                                           range: 5...50, unit: "%", step: 1,
                                           help: "电量低于阈值即暂停（与是否插电无关，充电时同样生效）；充至阈值 +5% 后才恢复，避免边界电量波动导致频繁抖动。")
                    }

                    smartPauseStatusRow
                }
            }

            Section("启动") {
                HStack(alignment: .top, spacing: 8) {
                    LaunchAtLoginToggle()
                    HelpButton(text: "登录时自动启动 WallFlux，常驻菜单栏。开关状态以系统为准，与菜单栏面板同步。")
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    /// 智能暂停当前命中状态（与菜单栏面板的「已暂停：[原因]」对应）
    private var smartPauseStatusRow: some View {
        let reasons = smartPauseMonitor.activeReasons
        return HStack(spacing: 8) {
            Image(systemName: reasons.isEmpty ? "checkmark.circle" : "pause.circle.fill")
                .foregroundStyle(reasons.isEmpty ? Color.green : Color.orange)
            Text(reasons.isEmpty ? "当前未命中任何暂停条件"
                 : "当前已暂停：\(reasons.map(\.displayName).joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// AppConfig 布尔字段绑定（写穿 ConfigStore 并触发壁纸/条件刷新）
    private func boolBinding(keyPath: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { configStore.config[keyPath: keyPath] },
            set: { newValue in configStore.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}