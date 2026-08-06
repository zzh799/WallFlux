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
            smartPauseHint
            HStack(spacing: 12) {
                Toggle("暂停播放", isOn: Binding(
                    get: { core.isPaused },
                    set: { core.isPaused = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                // 智能暂停命中时恢复按钮灰显：智能条件是硬门槛，不允许手动覆盖
                .disabled(!smartPauseReasons.isEmpty)
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

            Divider()
            HStack(spacing: 12) {
                LaunchAtLoginToggle(compact: true)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 智能暂停提示：命中时列出全部原因 + 解决指引（与手动暂停的「已暂停」区分）
    @ViewBuilder
    private var smartPauseHint: some View {
        let reasons = smartPauseReasons
        if !reasons.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("已暂停：\(reasons.map(\.displayName).joined(separator: "、"))")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(reasons.map(\.guidance).joined(separator: "；"))，或前往设置关闭对应条件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 所有显示器当前命中的智能暂停原因（并集，保持声明顺序）
    private var smartPauseReasons: [SmartPauseReason] {
        var seen = Set<SmartPauseReason>()
        return screenManager.contexts
            .flatMap(\.activeSmartPauseReasons)
            .filter { seen.insert($0).inserted }
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
                Text(subtitle)
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
        .accessibilityLabel("\(context.screen.localizedName)，\(subtitle)")
    }

    /// 状态副标题：智能暂停命中时显示「已暂停：[原因]」，与手动暂停区分
    private var subtitle: String {
        if context.isSmartPaused {
            return "已暂停：\(context.activeSmartPauseReasons.map(\.displayName).joined(separator: "、"))"
        }
        return "\(context.state.displayName) · \(context.wallpaperName)"
    }

    private var statusColor: Color {
        if context.isSmartPaused { return .gray }
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
