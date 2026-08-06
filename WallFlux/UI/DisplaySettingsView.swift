import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 显示器壁纸设置（FR-12 / FR-13）：来源选择与素材管理合一的左右分栏浏览器。
/// 左侧选择壁纸来源（系统 / 视频 / 图片序列）并提供导入入口，右侧以缩略图网格
/// 预览该来源全部素材（缩略图建立缓存），点击素材即应用为当前壁纸，导入素材可直接删除。
struct DisplaySettingsView: View {
    @ObservedObject private var core: CoreManager
    @ObservedObject private var screenManager: ScreenManager
    @ObservedObject private var configStore: ConfigStore
    @ObservedObject private var assetStore: AssetStore
    /// 素材缩略图缓存（后台生成，素材网格复用；共享实例跨窗口会话保持）
    @StateObject private var thumbnails = ThumbnailLoader.shared
    /// 当前选择的显示器 ID；空字符串表示未选择（视图会自动回退到第一个显示器）
    @State private var selectedDisplayID = ""
    /// 左侧选中的壁纸来源
    @State private var selectedType: WallpaperType = .system
    @State private var importError: String?

    init(core: CoreManager = CoreManager.shared) {
        self.core = core
        self.screenManager = core.screenManager
        self.configStore = core.configStore
        self.assetStore = core.assetStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            modePicker

            if configStore.config.wallpaperConfigMode == .allDisplays {
                sourceSplit
            } else if screenManager.contexts.isEmpty {
                emptyState
            } else {
                displayPicker
                sourceSplit
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            ensureValidSelection()
            syncTypeFromConfig()
            thumbnails.preload(assetsFor(selectedType))
        }
        .onChange(of: screenManager.contexts.map(\.displayID)) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: selectedDisplayID) { _, _ in
            syncTypeFromConfig()
        }
        .onChange(of: configStore.config.wallpaperConfigMode) { _, _ in
            ensureValidSelection()
            syncTypeFromConfig()
        }
        .onChange(of: selectedType) { _, newType in
            // 切换来源时预加载该来源全部素材缩略图，建立缓存
            thumbnails.preload(assetsFor(newType))
        }
    }

    // MARK: - 顶部控件

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

    // MARK: - 左右分栏

    /// 左右分栏：左侧来源栏 + 右侧素材预览网格
    private var sourceSplit: some View {
        HStack(spacing: 0) {
            sourceSidebar
            Divider()
            assetGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// 左侧来源栏：壁纸来源选择 + 对应导入入口
    private var sourceSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("壁纸来源")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ForEach(WallpaperType.allCases) { type in
                sourceRow(type)
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            Divider()
            sourceActions
                .padding(12)
        }
        .frame(width: 190)
    }

    private func sourceRow(_ type: WallpaperType) -> some View {
        let isSelected = type == selectedType
        return Button {
            selectType(type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sourceIcon(for: type))
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(type.displayName)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 来源栏底部操作区：视频可导入视频，图片序列可添加文件夹，系统壁纸不可管理
    @ViewBuilder
    private var sourceActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selectedType {
            case .video:
                Button(action: importVideo) {
                    Label("导入视频…", systemImage: "film.badge.plus")
                }
                .controlSize(.small)
            case .imageSequence:
                Button(action: importImageFolder) {
                    Label("添加文件夹…", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
            case .system:
                Label("系统壁纸由 macOS 提供，不可管理。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("导入错误：\(importError)")
            }
        }
    }

    /// 右侧素材预览：当前来源的全部素材缩略图网格，点击应用，导入素材可删除
    private var assetGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(selectedType.displayName)（\(assetsFor(selectedType).count)）")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if assetsFor(selectedType).isEmpty {
                emptyAssetsHint
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(assetsFor(selectedType)) { asset in
                            assetCell(asset)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyAssetsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedType == .system ? "sparkles" : "photo.badge.plus")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(emptyHintText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyHintText: String {
        switch selectedType {
        case .system: return "未发现系统动态壁纸。"
        case .video: return "还没有导入视频，点击左侧「导入视频…」添加。"
        case .imageSequence: return "还没有图片序列，点击左侧「添加文件夹…」添加。"
        }
    }

    /// 素材缩略图单元格：16:9 缩略图（缓存缺失时先显示占位）+ 名称 + 删除按钮
    private func assetCell(_ asset: WallpaperAsset) -> some View {
        let isSelected = asset.id == effectiveSelectedAssetID
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image = thumbnails.thumbnail(for: asset) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if asset.kind != .system {
                    Button(role: .destructive) {
                        deleteAsset(asset)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("删除 \(asset.name)")
                    .accessibilityLabel("删除 \(asset.name)")
                    .padding(6)
                }
            }

            Text(asset.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { selectAsset(asset) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(asset.name)
    }

    // MARK: - 数据

    private func assetsFor(_ type: WallpaperType) -> [WallpaperAsset] {
        assetStore.assets(for: type.assetKind)
    }

    private func sourceIcon(for type: WallpaperType) -> String {
        switch type {
        case .system: return "sparkles"
        case .video: return "film"
        case .imageSequence: return "photo.stack"
        }
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

    /// 网格高亮：当前配置在所选来源下实际生效的素材（配置失效时回退到该类型第一个可用素材）
    private var effectiveSelectedAssetID: String {
        let (type, assetID) = currentWallpaperSelection()
        guard type == selectedType else { return "" }
        if let asset = assetStore.asset(id: assetID), asset.kind == type.assetKind {
            return assetID
        }
        return assetStore.fallbackAsset(for: type.assetKind)?.id ?? ""
    }

    private func currentDisplayConfig(for id: String) -> DisplayConfig {
        core.configStore.config.displayConfigs.first { $0.displayID == id } ?? DisplayConfig(displayID: id)
    }

    private func displayLabel(for context: ScreenContext) -> String {
        let size = context.screen.frame.size
        return "\(context.screen.localizedName)（\(Int(size.width))×\(Int(size.height))）"
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

    /// 左侧来源与当前配置同步（切换配置方式 / 显示器后）
    private func syncTypeFromConfig() {
        selectedType = currentWallpaperSelection().type
    }

    // MARK: - 应用选择

    /// 选择壁纸来源：立即应用该类型，素材回退到该类型第一个可用素材
    private func selectType(_ type: WallpaperType) {
        selectedType = type
        let fallbackID = assetStore.fallbackAsset(for: type.assetKind)?.id ?? ""
        if configStore.config.wallpaperConfigMode == .allDisplays {
            configStore.update { config in
                config.sharedWallpaperType = type
                config.sharedWallpaperAssetID = fallbackID
                // 壁纸已变更：所有显示器从头播放
                for idx in config.displayConfigs.indices {
                    config.displayConfigs[idx].lastFramePosition = 0
                }
            }
        } else {
            guard !selectedDisplayID.isEmpty else { return }
            var dc = currentDisplayConfig(for: selectedDisplayID)
            dc.wallpaperType = type
            dc.wallpaperAssetID = fallbackID
            dc.lastFramePosition = 0
            configStore.updateDisplayConfig(dc)
        }
    }

    /// 选择素材：立即应用为当前（显示器 / 所有显示器）壁纸
    private func selectAsset(_ asset: WallpaperAsset) {
        if configStore.config.wallpaperConfigMode == .allDisplays {
            configStore.update { config in
                config.sharedWallpaperAssetID = asset.id
                for idx in config.displayConfigs.indices {
                    config.displayConfigs[idx].lastFramePosition = 0
                }
            }
        } else {
            guard !selectedDisplayID.isEmpty else { return }
            var dc = currentDisplayConfig(for: selectedDisplayID)
            dc.wallpaperAssetID = asset.id
            dc.lastFramePosition = 0
            configStore.updateDisplayConfig(dc)
        }
    }

    /// 删除导入素材；被删除素材正被使用时先回退到同类型第一个可用素材
    private func deleteAsset(_ asset: WallpaperAsset) {
        guard asset.kind != .system else { return }
        if effectiveSelectedAssetID == asset.id {
            let fallbackID = assetStore.fallbackAsset(for: asset.kind)?.id ?? ""
            if configStore.config.wallpaperConfigMode == .allDisplays {
                configStore.update { config in
                    config.sharedWallpaperAssetID = fallbackID
                }
            } else if !selectedDisplayID.isEmpty {
                var dc = currentDisplayConfig(for: selectedDisplayID)
                dc.wallpaperAssetID = fallbackID
                configStore.updateDisplayConfig(dc)
            }
        }
        thumbnails.remove(id: asset.id)
        assetStore.delete(asset)
    }

    // MARK: - 导入

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.title = "选择视频文件"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importError = nil
        for url in panel.urls {
            do {
                let asset = try assetStore.importVideo(from: url)
                selectImportedIfNothingValid(asset)
            } catch {
                importError = "导入失败：\(url.lastPathComponent)"
            }
        }
    }

    private func importImageFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择图片文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importError = nil
        do {
            let asset = try assetStore.importImageSequence(from: url)
            selectImportedIfNothingValid(asset)
        } catch {
            importError = "导入失败：\(url.lastPathComponent)"
        }
    }

    /// 当前壁纸尚未有效选择该类型素材时，导入后自动应用新素材
    private func selectImportedIfNothingValid(_ asset: WallpaperAsset) {
        let (type, assetID) = currentWallpaperSelection()
        let importedType = asset.kind == .video ? WallpaperType.video : .imageSequence
        guard type == importedType else { return }
        if let current = assetStore.asset(id: assetID), current.kind == asset.kind {
            return // 已有有效选择，不打断
        }
        selectAsset(asset)
    }
}
