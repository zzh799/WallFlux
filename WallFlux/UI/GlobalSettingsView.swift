import SwiftUI

/// 全局设置（FR-11）：闲置超时 N / 微跳间隔 Y / 微跳帧数 Z / 退出方式
/// + 设计文档：启动分区（开机自启）、智能暂停分区（总开关 + 5 个全局条件 + 低电量阈值）
struct GlobalSettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var smartPauseMonitor = CoreManager.shared.smartPauseMonitor

    var body: some View {
        Form {
            Section("闲置检测") {
                sliderRow(title: "闲置判定超时",
                          value: Binding(
                            get: { configStore.config.idleTimeoutMinutes },
                            set: { newValue in configStore.update { $0.idleTimeoutMinutes = newValue } }
                          ),
                          range: 1...60, unit: "分钟", step: 1)
                Text("显示器上超过该时长无鼠标或键盘输入，即判定为闲置并开始循环播放动态壁纸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("其他应用播放媒体时保持活跃", isOn: boolBinding(keyPath: \.mediaPlaybackKeepsActive))
                Text("系统正在输出声音的应用（播放音乐、视频、直播等，通过系统 CoreAudio 公开 API 检测）所在显示器不进入闲置循环播放，避免壁纸覆盖播放内容；声音停止后恢复。不影响微跳。常见音乐应用（网易云、Spotify、QQ 音乐等）预收集默认忽略名单：真实播放过声音后自动忽略（听歌时壁纸照常循环），可在「媒体应用」页查看名单并逐项管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("微跳模式") {
                sliderRow(title: "微跳间隔",
                          value: Binding(
                            get: { configStore.config.microStepIntervalSeconds },
                            set: { newValue in configStore.update { $0.microStepIntervalSeconds = newValue } }
                          ),
                          range: 1...300, unit: "秒", step: 1)
                stepperRow(title: "微跳帧数",
                           value: Binding(
                            get: { configStore.config.microStepFrameCount },
                            set: { newValue in configStore.update { $0.microStepFrameCount = newValue } }
                           ),
                           range: 1...10, unit: "帧")
                Text("活跃显示器不显示壁纸窗口，改为直接使用系统壁纸；每隔微跳间隔向前跳微跳帧数帧并直接修改系统壁纸，几乎不可察觉地防止烧屏。退出 WallFlux 时恢复原系统壁纸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("全屏应用中不微跳", isOn: Binding(
                    get: { configStore.config.microStepPauseOnFullscreen },
                    set: { newValue in configStore.update { $0.microStepPauseOnFullscreen = newValue } }
                ))
                Text("活跃显示器上存在全屏或最大化的应用窗口时不修改壁纸，避免在窗口之下频繁刷新桌面；退出全屏后自动恢复。闲置播放不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("退出方式") {
                sliderRow(title: "短暂进入宽限期",
                          value: Binding(
                            get: { configStore.config.briefEntryGraceSeconds },
                            set: { newValue in configStore.update { $0.briefEntryGraceSeconds = newValue } }
                          ),
                          range: 0...60, unit: "秒", step: 1)
                Text("鼠标短暂进入播放中的显示器时，壁纸立即让位（暂停并隐藏壁纸窗口，露出桌面）；宽限期内鼠标移出或停止移动则恢复置顶播放，持续移动满宽限期才退出。设为 0 秒表示鼠标进入立即退出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("退出方式", selection: Binding(
                    get: { configStore.config.exitMode },
                    set: { newValue in configStore.update { $0.exitMode = newValue } }
                )) {
                    ForEach(ExitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Text("显示器从闲置变为活跃时，壁纸以所选方式退出。渐隐过渡默认 0.5 秒淡出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("启动") {
                LaunchAtLoginToggle()
                Text("登录时自动启动 WallFlux，常驻菜单栏。开关状态以系统为准，与菜单栏面板同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("智能暂停") {
                Toggle("启用智能暂停", isOn: boolBinding(keyPath: \.smartPauseEnabled))
                Text("开启后，任一启用条件命中时完全暂停所有显示器的壁纸播放与微跳；关闭则回归纯手动控制，各条件开关保留配置但不生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if configStore.config.smartPauseEnabled {
                    Toggle("系统睡眠", isOn: boolBinding(keyPath: \.pauseOnSleep))
                    Toggle("显示器睡眠", isOn: boolBinding(keyPath: \.pauseOnDisplaySleep))
                    Toggle("低电量模式", isOn: boolBinding(keyPath: \.pauseOnLowPowerMode))
                    Toggle("电池供电", isOn: boolBinding(keyPath: \.pauseOnBattery))
                    Toggle("低电量", isOn: boolBinding(keyPath: \.pauseOnLowBattery))
                    if configStore.config.pauseOnLowBattery {
                        sliderRow(title: "低电量阈值",
                                  value: Binding(
                                    get: { configStore.config.lowBatteryThresholdPercent },
                                    set: { newValue in configStore.update { $0.lowBatteryThresholdPercent = newValue } }
                                  ),
                                  range: 5...50, unit: "%", step: 1)
                        Text("电量低于阈值即暂停（与是否插电无关，充电时同样生效）；充至阈值 +5% 后才恢复，避免边界电量波动导致频繁抖动。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    smartPauseStatusRow
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

    private func sliderRow(title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           unit: String,
                           step: Double) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 200)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value.wrappedValue)) \(unit)")
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        } label: {
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }

    private func stepperRow(title: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            unit: String) -> some View {
        LabeledContent {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) \(unit)")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue) \(unit)")
        } label: {
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }
}
