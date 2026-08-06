import AppKit
import SwiftUI

/// 菜单栏控制面板（FR-10）：显示器状态列表 + 快速暂停/恢复 + 设置入口
struct MenuBarPanelView: View {
    @ObservedObject var core: CoreManager
    @ObservedObject var screenManager: ScreenManager
    @ObservedObject var idleDetector: IdleDetector

    init(core: CoreManager) {
        self.core = core
        self.screenManager = core.screenManager
        self.idleDetector = core.idleDetector
    }

    var body: some View {
        VStack(spacing: 0) {
            if !idleDetector.isTrusted {
                PermissionWarningView(detector: idleDetector)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            }
            displayList
            footer
        }
        .frame(width: 320)
    }

    private var displayList: some View {
        let contexts = screenManager.contexts
        return ScrollView {
            VStack(spacing: 4) {
                ForEach(contexts) { context in
                    DisplayRow(context: context)
                }
            }
            .padding(16)
        }
        .frame(height: min(CGFloat(max(contexts.count, 1)) * 52 + 32, 300))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Toggle("暂停播放", isOn: Binding(
                    get: { core.isPaused },
                    set: { core.isPaused = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("暂停或恢复全部壁纸播放")

                Spacer()

                Button("设置…") {
                    SettingsWindowController.shared.show()
                }
                .controlSize(.small)

                Button("退出 WallFlux", role: .destructive) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
                .accessibilityLabel("退出 WallFlux")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// 单个显示器状态行
private struct DisplayRow: View {
    @ObservedObject var context: ScreenContext

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.screen.localizedName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(context.state.displayName) · \(context.wallpaperName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(context.screen.localizedName)，\(context.state.displayName)，壁纸 \(context.wallpaperName)")
    }

    private var statusColor: Color {
        switch context.state {
        case .active: return .green
        case .idle: return Color.accentColor
        case .exiting: return .orange
        }
    }
}

/// 辅助功能权限引导（首次使用需授权，见技术文档 §7）
private struct PermissionWarningView: View {
    @ObservedObject var detector: IdleDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("需要辅助功能权限")
                    .font(.body)
                    .fontWeight(.semibold)
                Spacer()
            }
            Text("WallFlux 需要辅助功能权限来检测输入活动，以便判断显示器是否闲置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("前往系统设置授权") {
                openAccessibilitySettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .combine)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
