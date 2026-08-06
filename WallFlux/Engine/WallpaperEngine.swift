import AppKit
import AVFoundation
import Foundation

/// 壁纸引擎：壁纸窗口创建/销毁与播放控制
final class WallpaperEngine {
    /// 退出淡出时长（FR-04 默认 0.5 秒）
    static let fadeOutDuration: TimeInterval = 0.5

    private var windows: [String: WallpaperWindow] = [:]

    /// 确保指定显示器存在壁纸窗口；素材变化时重建渲染内容
    func ensureWindow(displayID: String, screen: NSScreen, asset: WallpaperAsset) {
        if let window = windows[displayID] {
            if window.assetID != asset.id {
                window.reload(asset: asset, screen: screen)
            }
        } else {
            windows[displayID] = WallpaperWindow(screen: screen, asset: asset)
        }
    }

    func removeWindow(displayID: String) {
        windows.removeValue(forKey: displayID)?.destroy()
    }

    /// 屏幕参数变化时更新窗口位置
    func updateWindowFrame(displayID: String, screen: NSScreen) {
        windows[displayID]?.updateFrame(screen.frame)
    }

    func assetID(for displayID: String) -> String? {
        windows[displayID]?.assetID
    }

    func play(displayID: String) {
        windows[displayID]?.play()
    }

    /// 仅切换窗口层级（不改变播放状态）
    func setOnTop(displayID: String, onTop: Bool) {
        windows[displayID]?.setOnTop(onTop)
    }

    func pause(displayID: String) {
        windows[displayID]?.pause()
    }

    func stepForward(displayID: String, frames: Int) {
        windows[displayID]?.stepForward(frames: frames)
    }

    func seek(displayID: String, toFrame frame: Int) {
        windows[displayID]?.seek(toFrame: frame)
    }

    func currentFrame(displayID: String) -> Int? {
        windows[displayID]?.currentFrame
    }

    func fadeOut(displayID: String, duration: TimeInterval, completion: @escaping () -> Void) {
        windows[displayID]?.fadeOut(duration: duration, completion: completion)
    }
}
