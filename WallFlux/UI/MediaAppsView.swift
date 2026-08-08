import AppKit
import SwiftUI

/// 「媒体应用」设置页：出声应用的忽略管理
///
/// 主列表：本机播放过声音的应用（发现历史 + 正在出声的置顶），逐项「忽略」开关；
/// 被忽略的应用即使正在出声，也不阻止所在显示器进入闲置循环播放
/// （命中计算排除忽略名单，切换后立即重新评估放行），忽略名单持久化重启不丢。
///
/// 白名单（`MediaAppWhitelist`）：国内外常见音乐应用预收集名单，不在页面直接展示、
/// 也不预置忽略——应用真实出声时自动加入忽略名单（用户手动关闭过的键除外），
/// 名单可通过右下角「默认忽略应用」按钮弹窗只读查看。
/// 页面说明文字收纳在右下角感叹号按钮的气泡中，保持主界面干净。
struct MediaAppsView: View {
    @ObservedObject private var configStore = ConfigStore.shared
    @ObservedObject private var mediaMonitor = CoreManager.shared.mediaPlaybackMonitor

    /// 是否弹出感叹号说明气泡
    @State private var showInfoPopover = false
    /// 是否弹出默认忽略应用名单气泡
    @State private var showWhitelistPopover = false

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
            List(rows) { row in
                AudioAppRow(row: row,
                            isIgnored: configStore.config.ignoredAudioAppKeys.contains(row.record.key),
                            onToggleIgnore: { ignored in
                    toggleIgnore(key: row.record.key, ignored: ignored)
                })
            }
            .listStyle(.inset)

            // 右下角操作区：感叹号说明 + 默认忽略应用名单
            HStack(spacing: 8) {
                Spacer()
                Button(action: { showInfoPopover.toggle() }) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("媒体感知闲置的说明")
                .popover(isPresented: $showInfoPopover, arrowEdge: .bottom) {
                    InfoPopoverView()
                }

                Button {
                    showWhitelistPopover.toggle()
                } label: {
                    Label("默认忽略应用", systemImage: "music.note.list")
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showWhitelistPopover, arrowEdge: .bottom) {
                    WhitelistPopoverView()
                }
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 切换单个应用的忽略：关闭时若该键属于白名单，记入「不再自动忽略」，
    /// 避免下次出声时又被自动加入忽略名单
    private func toggleIgnore(key: String, ignored: Bool) {
        let whitelistKeys = Set(MediaAppWhitelist.allKeys)
        configStore.update { config in
            if ignored {
                if !config.ignoredAudioAppKeys.contains(key) {
                    config.ignoredAudioAppKeys.append(key)
                }
                config.mediaWhitelistUserExcludedKeys.removeAll { $0 == key }
            } else {
                config.ignoredAudioAppKeys.removeAll { $0 == key }
                if whitelistKeys.contains(key),
                   !config.mediaWhitelistUserExcludedKeys.contains(key) {
                    config.mediaWhitelistUserExcludedKeys.append(key)
                }
            }
        }
    }
}

/// 感叹号气泡：媒体感知闲置的机制说明
private struct InfoPopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("媒体感知闲置")
                .font(.headline)
            Text("其他应用正在输出声音（网页视频、直播、播放器、音乐等）时，所在显示器不进入闲置循环播放，避免壁纸覆盖播放内容；声音停止后恢复。通过系统 CoreAudio 公开 API 检测，无需任何权限，不影响微跳。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("本机播放过声音的应用会按每 2 秒检测累积记录，正在出声的置顶显示；点按「忽略」后，该应用即使正在出声也不会阻止所在显示器进入闲置循环播放。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("国内外常见音乐应用已列入「默认忽略应用」名单：它们一旦真实播放过声音，就会自动开启忽略（列表里可直接看到）；无需手动操作，手动关闭过的不会再自动加入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// 默认忽略应用名单气泡：白名单只读展示（国内外分组，图标 + 名称）
private struct WhitelistPopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("默认忽略应用")
                    .font(.headline)
                Text("名单中的应用一旦真实播放过声音，即自动加入忽略名单（所在显示器不再被阻止循环播放壁纸）；手动关闭该应用的「忽略」后，不再自动重新加入。视频/直播类媒体不在名单内，播放时保持活跃以保护画面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    whitelistSection(title: "国内", entries: MediaAppWhitelist.domestic)
                    whitelistSection(title: "国际", entries: MediaAppWhitelist.international)
                }
            }
            .frame(height: 320)
        }
        .frame(width: 320)
    }

    private func whitelistSection(title: String, entries: [MediaAppWhitelist.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    WhitelistAppIcon(entry: entry)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(entry.name)
                        .font(.callout)
                    Spacer(minLength: 0)
                    Text(entry.region.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }
}

/// 白名单应用图标（按首个 bundle ID 查找；未安装使用通用音符占位图标）
private struct WhitelistAppIcon: View {
    let entry: MediaAppWhitelist.Entry

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIDs[0]) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 单个应用的列表行
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
        // 浏览器音频辅助进程（如 com.google.Chrome.helper）用宿主应用图标
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