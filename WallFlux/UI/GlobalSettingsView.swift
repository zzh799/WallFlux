import SwiftUI

/// 全局设置（FR-11）：闲置超时 N / 微跳间隔 Y / 微跳帧数 Z / 退出方式
struct GlobalSettingsView: View {
    @ObservedObject private var configStore = ConfigStore.shared

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
                Text("活跃显示器保留壁纸窗口但不播放，每隔微跳间隔向前跳微跳帧数帧，几乎不可察觉地防止烧屏。")
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
                Text("鼠标短暂进入播放中的显示器时，壁纸立即让位（暂停并降至窗口之下）；宽限期内鼠标移出或停止移动则恢复置顶播放，持续移动满宽限期才退出。设为 0 秒表示鼠标进入立即退出。")
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
        }
        .formStyle(.grouped)
        .padding(20)
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
