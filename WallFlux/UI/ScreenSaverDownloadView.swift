import AppKit
import SwiftUI

/// 系统 Aerial 屏保下载中心（设置窗口 Sheet）：
/// 列出系统 Aerial 屏保全部资产（含未下载），支持分类筛选、下载进度、
/// 系统已下载素材直接设为壁纸（共用系统文件）、素材库下载与删除。
struct ScreenSaverDownloadView: View {
    @ObservedObject private var assetStore: AssetStore
    /// 「设为壁纸」回调（由父视图写入配置并应用）
    private let onUseAsset: (WallpaperAsset) -> Void
    @Environment(\.dismiss) private var dismiss
    /// 当前分类筛选（空字符串 = 全部）
    @State private var selectedCategoryID = ""
    /// 分类筛选弹窗状态
    @State private var showCategoryPicker = false
    @State private var downloadAlert: String?

    init(assetStore: AssetStore = AssetStore.shared, onUseAsset: @escaping (WallpaperAsset) -> Void) {
        self.assetStore = assetStore
        self.onUseAsset = onUseAsset
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider()
            itemList
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 540)
        .alert("下载失败", isPresented: Binding(
            get: { downloadAlert != nil },
            set: { if !$0 { downloadAlert = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(downloadAlert ?? "")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("屏幕保护下载中心")
                    .font(.headline)
                Text("系统 Aerial 航拍屏保素材 · 共 \(assetStore.aerialCatalog.count) 个视频（4K SDR 240fps）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("关闭")
        }
        .padding(14)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            categoryFilter
            Spacer()
            Text("已下载 \(downloadedCount)/\(filteredItems.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// 分类筛选：全部 + 系统分类（菜单式，避免横向拥挤）
    private var categoryFilter: some View {
        Menu {
            Button("全部") { selectedCategoryID = "" }
            ForEach(assetStore.aerialCategories) { category in
                Button(assetStore.aerialCategoryDisplayName(category)) {
                    selectedCategoryID = category.id
                }
            }
        } label: {
            Label(
                selectedCategoryID.isEmpty ? "全部分类" : (assetStore.aerialCategories.first { $0.id == selectedCategoryID }.map { assetStore.aerialCategoryDisplayName($0) } ?? "全部分类"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("筛选分类")
    }

    // MARK: - 列表

    private var filteredItems: [AerialCatalogItem] {
        guard !selectedCategoryID.isEmpty else { return assetStore.aerialCatalog }
        return assetStore.aerialCatalog.filter { $0.categories?.contains(selectedCategoryID) ?? false }
    }

    private var downloadedCount: Int {
        filteredItems.filter { assetStore.aerialAsset(for: $0.id) != nil }.count
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredItems) { item in
                    itemRow(item)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 单行资产：缩略图 + 名称/分类 + 状态（下载 / 进度 / 已下载操作）
    private func itemRow(_ item: AerialCatalogItem) -> some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: item.previewImage)
                .frame(width: 140, height: 79)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(assetStore.aerialDisplayName(for: item))
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let category = assetStore.aerialCategory(for: item) {
                        Text(assetStore.aerialCategoryDisplayName(category))
                            .foregroundStyle(.secondary)
                    }
                    if let sub = assetStore.aerialSubcategoryName(for: item) {
                        Text("· \(sub)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                Text("4K SDR 240fps")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusArea(item)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
    }

    /// 右侧状态区：已下载（操作按钮）/ 下载中（进度）/ 未下载（下载按钮）
    @ViewBuilder
    private func statusArea(_ item: AerialCatalogItem) -> some View {
        let itemID = item.id
        if let asset = assetStore.aerialAsset(for: itemID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(asset.kind == .screenSaver ? "系统已下载（共用）" : "已下载到素材库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Button {
                        onUseAsset(asset)
                    } label: {
                        Label("设为壁纸", systemImage: "photo.on.rectangle.angled")
                    }
                    .controlSize(.small)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([asset.url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .controlSize(.small)
                    .help("在 Finder 中显示")
                    .accessibilityLabel("在 Finder 中显示")

                    if asset.kind == .video {
                        Button(role: .destructive) {
                            deleteDownloaded(item, asset: asset)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .help("从素材库删除（不占用系统文件）")
                        .accessibilityLabel("删除素材库下载")
                    }
                }
            }
            .frame(width: 210, alignment: .trailing)
        } else if let progress = assetStore.downloadProgress[itemID] {
            VStack(alignment: .trailing, spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                HStack(spacing: 6) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        assetStore.cancelAerialDownload(itemID)
                    }
                    .controlSize(.mini)
                }
            }
            .frame(width: 210, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    assetStore.downloadAerialItem(item)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                if let error = assetStore.downloadErrors[itemID] {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
            }
            .frame(width: 210, alignment: .trailing)
        }
    }

    /// 删除素材库下载（正被使用时先回退到视频分类第一个可用素材，与主界面删除逻辑一致）
    private func deleteDownloaded(_ item: AerialCatalogItem, asset: WallpaperAsset) {
        let config = ConfigStore.shared.config
        let videoFallbackID = assetStore.fallbackAsset(for: .video)?.id ?? ""
        if config.wallpaperConfigMode == .allDisplays, config.sharedWallpaperAssetID == asset.id {
            ConfigStore.shared.update { $0.sharedWallpaperAssetID = videoFallbackID }
        } else if let dc = config.displayConfigs.first(where: { $0.wallpaperAssetID == asset.id }) {
            var fresh = dc
            fresh.wallpaperAssetID = videoFallbackID
            ConfigStore.shared.updateDisplayConfig(fresh)
        }
        assetStore.delete(asset)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Label("系统已下载的视频与系统屏保共用同一文件，不重复占空间；素材来自 Apple 官方 CDN。",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                openScreenSaverSettings()
            } label: {
                Label("在系统设置中启用", systemImage: "gearshape")
            }
            .help("打开系统屏幕保护设置，选择「Aerial」分类后系统会自动下载其余素材")
        }
        .padding(12)
    }

    /// 打开系统屏幕保护设置面板（x-apple.systempreferences 深链，已验证可用）
    private func openScreenSaverSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 远程图片加载（系统 Aerial 官方预览图；懒加载 + 内存缓存，失败显示占位）
struct RemoteImage: View {
    let urlString: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    Image(systemName: "film")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard image == nil, let urlString, let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let loaded = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                if self.image == nil {
                    self.image = loaded
                }
            }
        }.resume()
    }
}
