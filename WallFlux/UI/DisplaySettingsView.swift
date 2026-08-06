import AppKit
import SwiftUI

/// 显示器壁纸设置（FR-12）：所有显示器共享 / 逐显示器单独设置
struct DisplaySettingsView: View {
    @ObservedObject private var core: CoreManager
    @ObservedObject private var screenManager: ScreenManager
    @ObservedObject private var configStore: ConfigStore
    /// 当前选择的显示器 ID；空字符串表示未选择（视图会自动回退到第一个显示器）
    @State private var selectedDisplayID = ""
    @State private var previewImage: NSImage?

    init(core: CoreManager = CoreManager.shared) {
        self.core = core
        self.screenManager = core.screenManager
        self.configStore = core.configStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker

            if configStore.config.wallpaperConfigMode == .allDisplays {
                sharedSettingsForm
            } else if screenManager.contexts.isEmpty {
                emptyState
            } else {
                displayPicker
                if let context = selectedContext {
                    settingsForm(for: context)
                        .id(context.displayID)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            ensureValidSelection()
            loadPreview()
        }
        .onChange(of: screenManager.contexts.map(\.displayID)) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: selectedDisplayID) { _, _ in
            loadPreview()
        }
        .onChange(of: configStore.config.wallpaperConfigMode) { _, _ in
            ensureValidSelection()
            loadPreview()
        }
    }

    // MARK: - 子视图

    /// 配置方式单选：所有显示器 / 单独设置
    private var modePicker: some View {
        Picker("壁纸配置方式", selection: wallpaperModeBinding) {
            ForEach(WallpaperConfigMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
        .accessibilityLabel("壁纸配置方式")
    }

    private var displayPicker: some View {
        Picker("显示器", selection: $selectedDisplayID) {
            ForEach(screenManager.contexts) { context in
                Text(displayLabel(for: context)).tag(context.displayID)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 340, alignment: .leading)
        .accessibilityLabel("选择显示器")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("未检测到显示器")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("连接显示器后，壁纸配置会自动恢复。")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 所有显示器模式：共享壁纸配置，编辑一次应用到全部显示器
    private var sharedSettingsForm: some View {
        Form {
            Section("壁纸来源") {
                Picker("壁纸类型", selection: sharedTypeBinding) {
                    ForEach(WallpaperType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("壁纸素材", selection: sharedAssetBinding) {
                    ForEach(sharedAssetOptions) { asset in
                        Text(asset.name).tag(asset.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(sharedAssetOptions.isEmpty)
                .accessibilityLabel("壁纸素材")

                Text("所有显示器将使用同一壁纸，新接入的显示器自动沿用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("预览") {
                previewBox
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func settingsForm(for context: ScreenContext) -> some View {
        Form {
            Section("壁纸来源") {
                Picker("壁纸类型", selection: wallpaperTypeBinding) {
                    ForEach(WallpaperType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("壁纸素材", selection: wallpaperAssetBinding) {
                    ForEach(assetOptions) { asset in
                        Text(asset.name).tag(asset.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(assetOptions.isEmpty)
                .accessibilityLabel("壁纸素材")
            }

            Section("预览") {
                previewBox
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(4)
                    .accessibilityLabel("壁纸预览")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("暂无预览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
        .padding(.vertical, 8)
    }

    // MARK: - 数据

    private var selectedContext: ScreenContext? {
        guard !selectedDisplayID.isEmpty else { return nil }
        return screenManager.context(for: selectedDisplayID)
    }

    /// 配置方式切换绑定（写入 ConfigStore 并触发壁纸刷新）
    private var wallpaperModeBinding: Binding<WallpaperConfigMode> {
        Binding(
            get: { configStore.config.wallpaperConfigMode },
            set: { newMode in
                configStore.update { $0.wallpaperConfigMode = newMode }
            }
        )
    }

    // MARK: 所有显示器模式

    private var sharedAssetOptions: [WallpaperAsset] {
        core.assetStore.assets(for: configStore.config.sharedWallpaperType.assetKind)
    }

    private var sharedTypeBinding: Binding<WallpaperType> {
        Binding(
            get: { configStore.config.sharedWallpaperType },
            set: { newType in
                let fallbackID = core.assetStore.fallbackAsset(for: newType.assetKind)?.id ?? ""
                configStore.update { config in
                    config.sharedWallpaperType = newType
                    config.sharedWallpaperAssetID = fallbackID
                    // 壁纸已变更：所有显示器从头播放
                    for idx in config.displayConfigs.indices {
                        config.displayConfigs[idx].lastFramePosition = 0
                    }
                }
                refreshPreviewSoon()
            }
        )
    }

    private var sharedAssetBinding: Binding<String> {
        Binding(
            get: { configStore.config.sharedWallpaperAssetID },
            set: { newID in
                configStore.update { config in
                    config.sharedWallpaperAssetID = newID
                    for idx in config.displayConfigs.indices {
                        config.displayConfigs[idx].lastFramePosition = 0
                    }
                }
                refreshPreviewSoon()
            }
        )
    }

    // MARK: 单独设置模式

    private var assetOptions: [WallpaperAsset] {
        guard let type = selectedContext?.displayConfig.wallpaperType else { return [] }
        return core.assetStore.assets(for: type.assetKind)
    }

    private var wallpaperTypeBinding: Binding<WallpaperType> {
        Binding(
            get: {
                guard !selectedDisplayID.isEmpty else { return .system }
                return currentDisplayConfig(for: selectedDisplayID).wallpaperType
            },
            set: { newType in
                guard !selectedDisplayID.isEmpty else { return }
                var dc = currentDisplayConfig(for: selectedDisplayID)
                dc.wallpaperType = newType
                dc.wallpaperAssetID = core.assetStore.fallbackAsset(for: newType.assetKind)?.id ?? ""
                dc.lastFramePosition = 0
                core.configStore.updateDisplayConfig(dc)
                refreshPreviewSoon()
            }
        )
    }

    private var wallpaperAssetBinding: Binding<String> {
        Binding(
            get: {
                guard !selectedDisplayID.isEmpty else { return "" }
                return currentDisplayConfig(for: selectedDisplayID).wallpaperAssetID
            },
            set: { newID in
                guard !selectedDisplayID.isEmpty else { return }
                var dc = currentDisplayConfig(for: selectedDisplayID)
                dc.wallpaperAssetID = newID
                dc.lastFramePosition = 0
                core.configStore.updateDisplayConfig(dc)
                refreshPreviewSoon()
            }
        )
    }

    /// 当前生效的壁纸选择（按配置方式解析）
    private func currentWallpaperSelection() -> (type: WallpaperType, assetID: String) {
        if configStore.config.wallpaperConfigMode == .allDisplays {
            return (configStore.config.sharedWallpaperType, configStore.config.sharedWallpaperAssetID)
        }
        guard !selectedDisplayID.isEmpty else { return (.system, "") }
        let dc = currentDisplayConfig(for: selectedDisplayID)
        return (dc.wallpaperType, dc.wallpaperAssetID)
    }

    private func currentDisplayConfig(for id: String) -> DisplayConfig {
        core.configStore.config.displayConfigs.first { $0.displayID == id } ?? DisplayConfig(displayID: id)
    }

    private func displayLabel(for context: ScreenContext) -> String {
        let size = context.screen.frame.size
        return "\(context.screen.localizedName)（\(Int(size.width))×\(Int(size.height))）"
    }

    /// 确保选中项有效：显示器热插拔或列表变化后，失效的选中项自动回退到第一个显示器
    private func ensureValidSelection() {
        let ids = screenManager.contexts.map(\.displayID)
        guard !ids.isEmpty else {
            if !selectedDisplayID.isEmpty { selectedDisplayID = "" }
            return
        }
        if !ids.contains(selectedDisplayID) {
            selectedDisplayID = ids[0]
        }
    }

    private func refreshPreviewSoon() {
        DispatchQueue.main.async { loadPreview() }
    }

    private func loadPreview() {
        previewImage = nil
        let (type, assetID) = currentWallpaperSelection()
        if let asset = core.assetStore.asset(id: assetID) {
            previewImage = ThumbnailProvider.thumbnail(for: asset)
        } else if let fallback = core.assetStore.fallbackAsset(for: type.assetKind) {
            previewImage = ThumbnailProvider.thumbnail(for: fallback)
        }
    }
}
