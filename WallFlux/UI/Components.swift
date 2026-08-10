import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// 问号帮助按钮（设置表单行用）：悬停显示原生 tooltip，点击弹出说明气泡。
/// 帮助文本同时写入 accessibilityHint，屏幕阅读器可读。
struct HelpButton: View {
    let text: String
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("帮助")
        .accessibilityHint(text)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 设置页表单行统一样式（「全局 / 屏保 / 壁纸」三页共用）：
/// 标签 100pt + 控件 + 行尾「?」帮助按钮，说明文案不占表单行高。
enum SettingsRow {
    /// 滑块行：标签 + 滑块(200pt) + 数值(56pt) + 帮助按钮
    static func slider(title: String,
                       value: Binding<Double>,
                       range: ClosedRange<Double>,
                       unit: String,
                       step: Double,
                       help: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .frame(width: 200)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value.wrappedValue)) \(unit)")
                Text("\(Int(value.wrappedValue)) \(unit)")
                    .font(.body)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                HelpButton(text: help)
            }
        } label: {
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }

    /// 步进行：标签 + Stepper + 帮助按钮
    static func stepper(title: String,
                        value: Binding<Int>,
                        range: ClosedRange<Int>,
                        unit: String,
                        help: String) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Stepper(value: value, in: range) {
                    Text("\(value.wrappedValue) \(unit)")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityLabel(title)
                .accessibilityValue("\(value.wrappedValue) \(unit)")
                HelpButton(text: help)
            }
        } label: {
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }

    /// 开关行：标签左置、开关右置，帮助按钮在行尾
    static func toggle(title: String,
                       isOn: Binding<Bool>,
                       help: String) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: isOn)
            HelpButton(text: help)
        }
    }

    /// 选择行：标签 + 菜单 Picker + 帮助按钮
    static func menuPicker<SelectionValue: Hashable, Content: View>(
        title: String,
        selection: Binding<SelectionValue>,
        help: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(title, selection: selection, content: content)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .leading)
                HelpButton(text: help)
            }
        } label: {
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }
}

/// 开机自启开关（设计 §1）：SMAppService 为真相源，onAppear 时读取真实状态刷新，不做定时轮询。
/// 写穿：ON → register()；OFF → unregister()。
/// 审批状态（.requiresApproval）：开关亮（开）+ 警示文案 + 「打开系统设置」按钮。
/// - Parameters:
///   - compact: 紧凑模式（菜单栏面板用），仅展示开关与精简警示行
struct LaunchAtLoginToggle: View {
    var compact = false
    @State private var isOn = false
    @State private var requiresApproval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("开机自启", isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if newValue {
                        LaunchAtLogin.enable()
                    } else {
                        LaunchAtLogin.disable()
                    }
                    refresh()
                }
            ))
            .toggleStyle(.switch)
            .controlSize(compact ? .small : .regular)
            .accessibilityLabel("开机自启")

            if requiresApproval {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.yellow)
                    Text("需在系统设置中批准")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Button("打开系统设置") {
                        LaunchAtLogin.openSystemSettings()
                    }
                    .controlSize(compact ? .mini : .small)
                }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        isOn = LaunchAtLogin.isEnabled
        requiresApproval = LaunchAtLogin.requiresApproval
    }
}

/// 素材缩略图生成（不缓存；内存缓存由 ThumbnailLoader 统一负责）
enum ThumbnailProvider {
    static func thumbnail(for asset: WallpaperAsset, maxPixelSize: CGFloat = 480) -> NSImage? {
        switch asset.renderMode {
        case .video:
            return videoThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        case .imageSequence:
            return imageSequenceThumbnail(url: asset.url, maxPixelSize: maxPixelSize)
        }
    }

    private static func videoThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func imageSequenceThumbnail(url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// 素材缩略图异步加载器（为素材网格“建立缓存”）：主线程命中缓存即返回，
/// 未命中时后台生成并发布结果；素材被删除时同步清理缓存。
/// 共享实例：缓存跨设置窗口开关保持，同一素材不重复生成缩略图
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    @Published private(set) var images: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "com.wallflux.WallFlux.ThumbnailLoader", qos: .userInitiated)
    private var pending = Set<String>()

    private init() {}

    /// 取缩略图：缓存命中立即返回；未命中触发后台生成，返回 nil（视图先显示占位）
    func thumbnail(for asset: WallpaperAsset, maxPixelSize: CGFloat = 480) -> NSImage? {
        if let image = images[asset.id] { return image }
        schedule(asset, maxPixelSize: maxPixelSize)
        return nil
    }

    /// 预加载一组素材的缩略图（后台生成，不阻塞 UI）
    func preload(_ assets: [WallpaperAsset], maxPixelSize: CGFloat = 480) {
        for asset in assets where images[asset.id] == nil {
            schedule(asset, maxPixelSize: maxPixelSize)
        }
    }

    /// 素材被删除时清理其缓存
    func remove(id: String) {
        images[id] = nil
    }

    private func schedule(_ asset: WallpaperAsset, maxPixelSize: CGFloat) {
        guard !pending.contains(asset.id) else { return }
        pending.insert(asset.id)
        queue.async { [weak self] in
            guard let self else { return }
            let image = ThumbnailProvider.thumbnail(for: asset, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async {
                self.pending.remove(asset.id)
                if let image {
                    self.images[asset.id] = image
                }
            }
        }
    }
}
