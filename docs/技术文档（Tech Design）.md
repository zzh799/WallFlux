# 动态壁纸配置程序 — 技术文档（Tech Design）

## 1. 技术栈

| 层 | 技术 |
|----|------|
| UI 框架 | SwiftUI（菜单栏、设置窗口） |
| 底层桥接 | AppKit（壁纸窗口、窗口层级控制） |
| 视频渲染 | AVFoundation + VideoToolbox（硬件解码） |
| 输入监控 | CGEvent（Core Graphics 事件监听） |
| 显示器管理 | NSScreen + CGDisplay |
| 配置持久化 | UserDefaults / plist |
| 语言 | Swift 5.9+ |
| 最低系统 | macOS 14.0 |
| 打包 | DMG + Homebrew Cask |

---

## 2. 架构设计

### 2.1 模块划分

```
App/
├── MenuBar/                    # 菜单栏入口
│   ├── AppDelegate.swift       # NSApplicationDelegate
│   └── MenuBarView.swift       # 菜单栏 SwiftUI 视图
├── Settings/                   # 配置窗口
│   ├── SettingsWindow.swift    # NSWindow + HostingController
│   ├── SettingsView.swift      # SwiftUI 设置界面
│   └── MonitorConfigView.swift # 单显示器配置行
├── Wallpaper/                  # 壁纸引擎核心
│   ├── WallpaperEngine.swift   # 引擎总控（协调所有显示器）
│   ├── MonitorWallpaper.swift  # 单显示器壁纸管理器
│   ├── WallpaperWindow.swift   # AppKit 壁纸覆盖窗口
│   ├── VideoRenderer.swift     # AVPlayer 视频渲染
│   ├── ImageSequenceRenderer.swift # 图片序列渲染
│   └── WallpaperSource.swift   # 壁纸素材模型
├── InputMonitor/               # 输入监控
│   ├── InputMonitor.swift      # CGEvent 全局事件监听
│   └── IdleDetector.swift      # 闲置判定逻辑
├── DisplayManager/             # 显示器管理
│   ├── DisplayManager.swift    # NSScreen 监听 + 热插拔
│   └── DisplayIdentity.swift   # 显示器唯一标识
├── Configuration/              # 配置管理
│   ├── AppConfig.swift         # 全局配置模型
│   └── ConfigStore.swift       # UserDefaults 读写
└── Distribution/               # 分发
    ├── DMG/
    └── Homebrew/
```

### 2.2 核心类图（简略）

```
WallpaperEngine (1) ──────── (N) MonitorWallpaper
     │                               │
     │ owns                          │ owns
     ▼                               ▼
InputMonitor                    WallpaperWindow (NSWindow, kCGDesktopWindowLevel)
IdleDetector                         │
     │                               │ contains
     │                               ▼
     └────────── uses ────────▶ AVPlayer / ImageSequencePlayer
```

---

## 3. 关键实现细节

### 3.1 壁纸窗口

```swift
// 窗口层级：桌面图标之上，普通窗口之下
window.level = NSWindow.Level(rawValue: kCGDesktopWindowLevel)

// 覆盖整个目标显示器
window.setFrame(screen.frame, display: true)

// 无视鼠标事件（点击穿透到桌面图标/窗口）
window.ignoresMouseEvents = true

// 无标题栏、无阴影、不可移动
window.styleMask = [.borderless]
window.isOpaque = true
window.backgroundColor = .black
window.hasShadow = false
```

### 3.2 闲置判定算法

```
1. 全局监听 CGEvent（mouseMoved, keyDown 等）
2. 每次事件时：
   a. 记录事件时间戳
   b. 如果是鼠标事件：获取鼠标位置 → NSScreen.screens 中确认所在显示器 → 该显示器标记活跃
   c. 如果是键盘事件：所有显示器标记活跃
3. 每 1 秒轮询检查：
   - 对每个显示器：计算 (当前时间 - 该显示器最后活跃时间)
   - 若超过闲置阈值 && 当前非闲置 → 触发壁纸播放
   - 若低于阈值 && 当前是闲置 → 触发壁纸退出
```

### 3.3 微跳模式

```
活跃显示器状态机：
IDLE_PLAYING → (用户回来) → MICRO_STEPPING

MICRO_STEPPING 模式：
- AVPlayer.rate = 0（暂停）
- Timer 每 Y 秒触发：
  1. 记录当前 CMTime
  2. seek(to: currentTime + Z 帧对应时长)
  3. 等待 seek 完成（异步），期间保持暂停
  4. 立即再次暂停（确保只显示一帧）
```

### 3.4 显示器 ID 方案

```swift
// 用于记住配置的唯一标识
struct DisplayIdentity: Codable, Hashable {
    let vendorNumber: UInt32    // CGDisplayVendorNumber
    let modelNumber: UInt32     // CGDisplayModelNumber
    let serialNumber: UInt32    // CGDisplaySerialNumber
    // 若三者相同（如同型号），追加 displayIndex 区分
    let displayIndex: Int
}
```

### 3.5 输入监控权限

需要 `kAXTrustedCheckOptionPrompt` 申请辅助功能权限。不使用 IOKit 隐藏 API。

### 3.6 配置数据结构

```swift
struct AppConfig: Codable {
    var idleTimeoutMinutes: Int = 5       // 闲置阈值
    var microStepIntervalSeconds: Int = 15 // 微跳间隔
    var microStepFrames: Int = 1           // 每次跳帧数
    var exitTransition: ExitTransition = .fadeOut(duration: 0.8) // 退出方式
    var launchAtLogin: Bool = true
}

struct MonitorConfig: Codable {
    var displayID: DisplayIdentity
    var wallpaperSource: WallpaperSource   // 系统/视频/图片序列
}

struct WallpaperSource: Codable {
    enum SourceType: String, Codable {
        case systemBuiltIn             // 系统动态桌面
        case localVideo(path: String)  // 本地视频
        case imageSequence(path: String, fps: Int) // 图片序列
    }
}
```

---

## 4. 渲染管线

```
                    ┌──────────────────────┐
                    │   WallpaperEngine     │
                    │  (协调者，持有所有      │
                    │   MonitorWallpaper)    │
                    └──────┬───────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        MonitorWP-1  MonitorWP-2  MonitorWP-3
              │            │            │
              ▼            ▼            ▼
        WallpaperWindow  (每个显示器一个 NSWindow)
              │
     ┌────────┼────────┐
     ▼                 ▼
  AVPlayer        ImageSequencePlayer
 (视频源)          (图片序列源)
     │                 │
     ▼                 ▼
  VideoToolbox     CGImage/CALayer
  (硬件解码)        (逐帧渲染)
```

---

## 5. 数据流

```
CGEvent (鼠标/键盘)
    │
    ▼
InputMonitor ──▶ IdleDetector ──▶ WallpaperEngine
                                      │
                    ┌─────────────────┼──────────────────┐
                    ▼                 ▼                  ▼
            MonitorWallpaper   MonitorWallpaper   MonitorWallpaper
              (Displays A)      (Displays B)       (Displays C)
                    │                 │                  │
              ┌─────┴─────┐     ┌─────┴─────┐      ┌─────┴─────┐
              ▼           ▼     ▼           ▼      ▼           ▼
          idlePlay   microStep  idlePlay   microStep  idlePlay   microStep
```

---

## 6. 风险与对策

| 风险 | 影响 | 对策 |
|------|------|------|
| `kCGDesktopWindowLevel` 在 macOS 新版本变化 | 壁纸层级不正确 | 增加运行时检测，fallback 到 `kCGDesktopIconWindowLevel - 1` |
| AVPlayer seek 精度不足 | 跳帧不精确 | 使用 `seek(toleranceBefore: .zero, toleranceAfter: .zero)` |
| 同型号显示器 ID 冲突 | 配置错乱 | 追加 displayIndex 降级区分 |
| 系统动态壁纸 API 限制 | 无法逐帧控制 | 对系统壁纸仅在闲置时全屏循环，微跳时不使用系统壁纸 |
| 辅助功能权限申请被拒 | 无法监控输入 | 启动时引导用户开启，否则退化为全局闲置判定 |

---

## 7. 开发阶段

| 阶段 | 内容 | 预估工作量 |
|------|------|-----------|
| P0 - 原型 | 壁纸窗口 + 视频播放 + 单显示器闲置循环 | 3-5 天 |
| P1 - 核心 | 输入监控 + 多显示器 + 闲置/活跃切换 + 微跳 | 5-7 天 |
| P2 - 配置 | 设置界面 + 配置持久化 + 素材导入 | 3-5 天 |
| P3 - 体验 | 菜单栏 + 热插拔 + 渐隐过渡 + 登录自启 | 3-4 天 |
| P4 - 分发 | DMG 打包 + Homebrew Cask + 签名公证 | 2-3 天 |

---
