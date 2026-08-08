import AppKit
import SwiftUI

/// 菜单栏控制面板（FR-10）：显示器状态列表 + 最近使用快速切换 + 快速暂停/恢复 + 设置/退出入口
struct MenuBarPanelView: View {
    @ObservedObject var core: CoreManager
    @ObservedObject var screenManager: ScreenManager
    @ObservedObject var idleDetector: IdleDetector
    @ObservedObject private var configStore: ConfigStore
    @ObservedObject private var assetStore: AssetStore
    /// 会话内最近使用快照：面板打开时读取，点击切换后不实时重排（列表保持稳定），
    /// 下次打开面板时（panelSessionID 变化）按最新排序重建
    @State private var recentSnapshot: [WallpaperAsset] = []

    init(core: CoreManager) {
        self.core = core
        self.screenManager = core.screenManager
        self.idleDetector = core.idleDetector
        self.configStore = core.configStore
        self.assetStore = core.assetStore
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
            recentSection
            footer
        }
        .frame(width: 320)
        .onAppear { recentSnapshot = resolveRecentAssets() }
        // 面板每次打开（panelSessionID 递增）刷新快照：切换过的壁纸排序在下次打开时生效
        .onChange(of: core.panelSessionID) { _, _ in
            recentSnapshot = resolveRecentAssets()
        }
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

    /// 最近使用壁纸（FR-10 快速切换）：最近 3 个使用过的壁纸缩略图横排，点击应用到所有显示器
    @ViewBuilder
    private var recentSection: some View {
        if !recentSnapshot.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("最近使用", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(recentSnapshot) { asset in
                        RecentWallpaperButton(
                            asset: asset,
                            isCurrent: isCurrentAsset(asset)
                        ) {
                            quickApply(asset)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    /// 从持久化配置解析最近使用壁纸（最多 3 个；素材已删除或类型不匹配的自动剔除）
    private func resolveRecentAssets() -> [WallpaperAsset] {
        configStore.config.recentWallpapers
            .prefix(3)
            .compactMap { record in
                guard let asset = assetStore.asset(id: record.assetID),
                      WallpaperType(assetKind: asset.kind) == record.type else { return nil }
                return asset
            }
    }

    /// 素材是否当前生效：所有显示模式对比共享壁纸；单独设置模式任一显示器使用即高亮
    private func isCurrentAsset(_ asset: WallpaperAsset) -> Bool {
        let config = configStore.config
        if config.wallpaperConfigMode == .allDisplays {
            return config.sharedWallpaperAssetID == asset.id
                && config.sharedWallpaperType == WallpaperType(assetKind: asset.kind)
        }
        return config.displayConfigs.contains { $0.wallpaperAssetID == asset.id }
    }

    /// 最近使用快捷切换：应用到所有显示器（原子写入 + 记录最近使用，配置变更自动刷新壁纸）
    private func quickApply(_ asset: WallpaperAsset) {
        guard let type = WallpaperType(assetKind: asset.kind) else { return }
        configStore.quickApplyWallpaper(type: type, assetID: asset.id)
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

            Divider()
            // 底部操作行：设置与退出固定在面板底部（见设计规范 §5.1）
            HStack(spacing: 12) {
                Button("设置…") {
                    SettingsWindowController.shared.show()
                }
                .controlSize(.small)

                Spacer()

                Button("退出 WallFlux", role: .destructive) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
                .accessibilityLabel("退出 WallFlux")
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

/// 最近使用壁纸按钮：16:9 缩略图 + 名称，点击快速应用到所有显示器；当前生效中的描边高亮
private struct RecentWallpaperButton: View {
    @ObservedObject private var thumbnails = ThumbnailLoader.shared

    let asset: WallpaperAsset
    let isCurrent: Bool
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            VStack(spacing: 4) {
                thumbnail
                Text(asset.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 88)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("切换到壁纸 \(asset.name)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// 16:9 缩略图（缓存缺失时先显示占位图标，后台生成后自动更新）
    private var thumbnail: some View {
        let image = thumbnails.thumbnail(for: asset, maxPixelSize: 240)
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 88, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 1.5)
        )
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
