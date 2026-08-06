import AppKit
import SwiftUI

/// 逐显示器设置（FR-12）：壁纸来源选择 + 素材选择 + 预览
struct DisplaySettingsView: View {
    @ObservedObject private var core: CoreManager
    @ObservedObject private var screenManager: ScreenManager
    @State private var selectedDisplayID: String?
    @State private var previewImage: NSImage?

    init(core: CoreManager = CoreManager.shared) {
        self.core = core
        self.screenManager = core.screenManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if screenManager.contexts.isEmpty {
                emptyState
            } else {
                Picker("显示器", selection: $selectedDisplayID) {
                    ForEach(screenManager.contexts) { context in
                        Text(displayLabel(for: context)).tag(context.displayID)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 340, alignment: .leading)
                .accessibilityLabel("选择显示器")

                if let context = selectedContext {
                    settingsForm(for: context)
                        .id(context.displayID)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selectedDisplayID == nil {
                selectedDisplayID = screenManager.contexts.first?.displayID
            }
            loadPreview()
        }
        .onChange(of: selectedDisplayID) { _, _ in
            loadPreview()
        }
    }

    // MARK: - 子视图

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
        guard let id = selectedDisplayID else { return nil }
        return screenManager.context(for: id)
    }

    private var assetOptions: [WallpaperAsset] {
        guard let type = selectedContext?.displayConfig.wallpaperType else { return [] }
        return core.assetStore.assets(for: type.assetKind)
    }

    private var wallpaperTypeBinding: Binding<WallpaperType> {
        Binding(
            get: {
                guard let id = selectedDisplayID else { return .system }
                return core.configStore.config.displayConfigs.first { $0.displayID == id }?.wallpaperType ?? .system
            },
            set: { newType in
                guard let id = selectedDisplayID else { return }
                var dc = currentDisplayConfig(for: id)
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
                guard let id = selectedDisplayID else { return "" }
                return core.configStore.config.displayConfigs.first { $0.displayID == id }?.wallpaperAssetID ?? ""
            },
            set: { newID in
                guard let id = selectedDisplayID else { return }
                var dc = currentDisplayConfig(for: id)
                dc.wallpaperAssetID = newID
                dc.lastFramePosition = 0
                core.configStore.updateDisplayConfig(dc)
                refreshPreviewSoon()
            }
        )
    }

    private func currentDisplayConfig(for id: String) -> DisplayConfig {
        core.configStore.config.displayConfigs.first { $0.displayID == id } ?? DisplayConfig(displayID: id)
    }

    private func displayLabel(for context: ScreenContext) -> String {
        let size = context.screen.frame.size
        return "\(context.screen.localizedName)（\(Int(size.width))×\(Int(size.height))）"
    }

    private func refreshPreviewSoon() {
        DispatchQueue.main.async { loadPreview() }
    }

    private func loadPreview() {
        previewImage = nil
        guard let id = selectedDisplayID else { return }
        let dc = core.configStore.config.displayConfigs.first { $0.displayID == id } ?? DisplayConfig(displayID: id)
        if let asset = core.assetStore.asset(id: dc.wallpaperAssetID) {
            previewImage = ThumbnailProvider.thumbnail(for: asset)
        } else if let fallback = core.assetStore.fallbackAsset(for: dc.wallpaperType.assetKind) {
            previewImage = ThumbnailProvider.thumbnail(for: fallback)
        }
    }
}
