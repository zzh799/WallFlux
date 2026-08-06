import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 素材管理（FR-13 / FR-05）：导入视频、导入图片文件夹、浏览与删除
struct AssetManagementView: View {
    @ObservedObject private var core: CoreManager
    @ObservedObject private var assetStore: AssetStore
    @State private var importError: String?

    init(core: CoreManager = CoreManager.shared) {
        self.core = core
        self.assetStore = core.assetStore
    }

    private var videos: [WallpaperAsset] {
        assetStore.importedAssets.filter { $0.kind == .video }
    }

    private var imageSequences: [WallpaperAsset] {
        assetStore.importedAssets.filter { $0.kind == .imageSequence }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button("导入视频…", action: importVideo)
                Button("导入图片文件夹…", action: importImageFolder)
                Spacer()
            }
            .controlSize(.regular)

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("导入错误：\(importError)")
            }

            List {
                Section {
                    if videos.isEmpty && imageSequences.isEmpty {
                        Text("还没有导入素材。支持 mp4 / mov / m4v 视频，或包含图片文件的文件夹。")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(videos) { asset in
                        assetRow(asset)
                    }
                    ForEach(imageSequences) { asset in
                        assetRow(asset)
                    }
                } header: {
                    Text("我的素材")
                }

                Section {
                    ForEach(assetStore.systemAssets) { asset in
                        HStack(spacing: 12) {
                            assetThumbnail(asset, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.name)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(asset.kindDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("系统动态壁纸（不可删除）")
                }
            }
            .listStyle(.inset)
        }
        .padding(20)
    }

    // MARK: - 行视图

    private func assetRow(_ asset: WallpaperAsset) -> some View {
        HStack(spacing: 12) {
            assetThumbnail(asset, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name)
                    .font(.body)
                    .lineLimit(1)
                Text(asset.kindDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                assetStore.delete(asset)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除素材")
            .accessibilityLabel("删除 \(asset.name)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func assetThumbnail(_ asset: WallpaperAsset, size: CGFloat) -> some View {
        if let image = ThumbnailProvider.thumbnail(for: asset, maxPixelSize: 240) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: size, height: size * 9 / 16)
                .overlay {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
        }
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
                try assetStore.importVideo(from: url)
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
            try assetStore.importImageSequence(from: url)
        } catch {
            importError = "导入失败：\(url.lastPathComponent)"
        }
    }
}
