import AppKit
import SwiftUI

/// 「声音应用」设置页：本机播放过声音的应用的忽略管理（方案 B'）
///
/// 列表内容：MediaPlaybackMonitor 通过 CoreAudio 进程级公开 API 累积发现的应用
/// （PID → BundleID → 名称/图标 + 最近播放时间），正在出声的置顶并标记。
/// 手动忽略：每个应用一个「忽略」开关；被忽略的应用即使正在出声，也不阻止
/// 所在显示器进入闲置循环播放（命中计算排除忽略名单，切换后立即重新评估放行）。
/// 忽略名单与发现历史由 ConfigStore 持久化（UserDefaults），重启不丢。
struct AudioAppsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var mediaMonitor = CoreManager.shared.mediaPlaybackMonitor

    /// 合并后的列表行：发现历史 + 当前正在出声的应用（按「正在播放 → 最近播放时间」排序）
    private var rows: [AudioRow] {
        var byKey: [String: AudioRow] = [:]
        for record in configStore.config.audioAppHistory {
            byKey[record.key] = AudioRow(record: record, isPlaying: false)
        }
        for app in mediaMonitor.nowPlayingApps {
            if var row = byKey[app.key] {
                row.isPlaying = true
                byKey[app.key] = row
            } else {
                byKey[app.key] = AudioRow(record: app, isPlaying: true)
            }
        }
        return byKey.values.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.record.lastPlayedAt > rhs.record.lastPlayedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本机播放过声音的应用（系统正在出声的应用按每 2 秒检测累积记录）。正在出声的应用置顶显示；点按「忽略」后，该应用即使正在出声也不会阻止所在显示器进入闲置循环播放。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "尚未发现播放过声音的应用",
                    systemImage: "speaker.wave.2",
                    description: Text("播放一次音乐、视频或直播后会自动出现在这里。")
                )
                Spacer()
            } else {
                List(rows) { row in
                    AudioAppRow(row: row,
                                isIgnored: configStore.config.ignoredAudioAppKeys.contains(row.record.key),
                                onToggleIgnore: { ignored in
                        configStore.update { config in
                            if ignored {
                                if !config.ignoredAudioAppKeys.contains(row.record.key) {
                                    config.ignoredAudioAppKeys.append(row.record.key)
                                }
                            } else {
                                config.ignoredAudioAppKeys.removeAll { $0 == row.record.key }
                            }
                        }
                    })
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 单个应用的列表行：图标 + 名称 + 状态/最近播放时间 + 忽略开关
private struct AudioRow: Identifiable {
    let record: AudioAppRecord
    var isPlaying: Bool
    var id: String { record.key }
}

private struct AudioAppRow: View {
    let row: AudioRow
    let isIgnored: Bool
    let onToggleIgnore: (Bool) -> Void

    /// 应用图标：优先按 Bundle ID 取；无 Bundle ID 或取不到（如 Chrome 音频辅助进程）
    /// 时按宿主应用回落；都没有则用通用图标。
    private var icon: NSImage? {
        guard let bundleID = row.record.bundleID else { return nil }
        // 浏览器音频辅助进程（com.google.Chrome.helper）用宿主应用（com.google.Chrome）图标
        var candidate = bundleID
        if candidate.hasSuffix(".helper") {
            candidate = String(candidate.dropLast(".helper".count))
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var statusText: String {
        if row.isPlaying {
            return "正在播放"
        }
        return "最近播放 \(row.record.lastPlayedAt.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(row.record.name)
                    .font(.body)
                HStack(spacing: 4) {
                    if row.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Toggle("忽略", isOn: Binding(
                get: { isIgnored },
                set: { onToggleIgnore($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel("忽略 \(row.record.name)")
            .help(isIgnored ? "已忽略：该应用正在出声时仍可进入闲置循环播放" : "忽略后，该应用正在出声时不阻止闲置循环播放")
        }
        .padding(.vertical, 2)
    }
}