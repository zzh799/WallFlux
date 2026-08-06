
## 技术设计文档

### 1. 技术栈

| 层 | 技术选型 |
|----|----------|
| UI 层（菜单栏 + 设置） | SwiftUI |
| 底层窗口管理 | AppKit（NSWindow, NSScreen） |
| 视频播放 | AVFoundation（AVPlayer, AVPlayerLayer） |
| 图片序列播放 | CoreAnimation / 手动帧切换 |
| 输入监控 | CGEvent（CGEventTap）或 IOKit HID |
| 存储 | UserDefaults + Codable（配置文件） |
| 构建 | Xcode 15+, Swift 5.9+ |
| 分发 | DMG + Homebrew Cask |

### 2. 系统架构

```
┌──────────────────────────────────────────────┐
│                   MenuBarApp                  │
│  ┌──────────┐  ┌──────────────────────────┐  │
│  │ MenuBar  │  │   SettingsWindow (SwiftUI) │  │
│  │ Controller│  │   - 全局设置              │  │
│  │ (SwiftUI) │  │   - 显示器壁纸设置        │  │
│  │          │  │   - 显示器壁纸设置（含素材管理分栏）   │  │
│  └────┬─────┘  └───────────┬──────────────┘  │
│       │                    │                  │
│  ┌────┴────────────────────┴──────────────┐   │
│  │           CoreManager                   │   │
│  │  - 显示器管理 (ScreenManager)           │   │
│  │  - 闲置检测 (IdleDetector)             │   │
│  │  - 配置管理 (ConfigStore)              │   │
│  │  - 素材管理 (AssetStore)               │   │
│  └────┬───────────────────────────────────┘   │
│       │                                       │
│  ┌────┴───────────────────────────────────┐   │
│  │          WallpaperEngine                │   │
│  │  - 窗口创建/销毁 (AppKit NSWindow)      │   │
│  │  - 视频渲染 (AVPlayer)                 │   │
│  │  - 图片序列渲染                        │   │
│  │  - 播放控制 (播放/暂停/跳帧)            │   │
│  └────────────────────────────────────────┘   │
└──────────────────────────────────────────────┘
```

### 3. 核心模块设计

#### 3.1 ScreenManager — 显示器管理器

- 职责：管理所有在线显示器的状态与壁纸窗口生命周期
- 关键能力：
  - 启动时枚举所有 NSScreen，为每个创建 ScreenContext
  - 监听 `NSApplication.didChangeScreenParametersNotification` 处理热插拔
  - 通过显示器唯一 ID（`NSScreen.displayID` 或序列号）匹配配置
  - 为每个显示器维护状态机：`active` / `idle` / `microStep`

- 数据结构：
  - `ScreenContext`：绑定 NSScreen 实例、当前壁纸窗口引用、当前状态、配置引用、闲置计时器、微跳计时器

#### 3.2 IdleDetector — 闲置检测器

- 职责：监控全局输入事件，判定各显示器的活跃/闲置状态
- 关键能力：
  - 通过 `CGEvent.tapCreate` 监听全局鼠标移动和键盘事件
  - 输入事件分为弱输入与强输入：纯鼠标移动为弱输入（走短暂进入宽限机制）；点击/拖拽/滚动为强输入（立即响应）；键盘为强输入
  - 鼠标事件：获取鼠标当前位置 `NSEvent.mouseLocation`，通过 `NSScreen.screens` 遍历判断落在哪个显示器，将该显示器标记为活跃
  - 键盘事件：通过 AX API 查询聚焦窗口（`kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute`），以窗口中心点所在显示器为准标记活跃；AX 查询失败（系统繁忙 `kAXErrorCannotComplete` 等）时逐级回退：鼠标位置所在屏 → 前台应用窗口（CGWindowList，无需权限）→ 最后才回退所有显示器（保守防烧屏）；查询带 0.5 秒节流缓存
  - 活跃事件发生后，重置对应显示器的闲置倒计时器
  - 闲置倒计时到期后，通知 ScreenManager 将对应显示器切换为 idle

- 注意事项：
  - `CGEventTap` 需要辅助功能权限，应用需引导用户授权
  - 必须处理事件 tap 被系统终止后的重连

#### 3.3 WallpaperEngine — 壁纸引擎

- 职责：管理桌面层级覆盖窗口，负责视频和图片序列的渲染与播放控制
- 窗口创建（AppKit）：
  - 为每个目标显示器创建 `NSWindow`
  - **动态层级**：播放时 `level = kCGScreenSaverWindowLevel`（屏保层级，置顶覆盖普通窗口与菜单栏）；暂停/微跳时降回 `kCGDesktopIconWindowLevel`（桌面图标层，普通窗口之下）
  - 设置 `collectionBehavior = [.canJoinAllSpaces, .stationary]`（跟随 Spaces 切换）
  - 窗口无边框、全屏覆盖目标 NSScreen 的 frame
  - 设置 `ignoresMouseEvents = true`（不拦截鼠标事件）
  - 背景色为黑色（视频未加载时）

- 视频渲染：
  - 使用 `AVPlayer` + `AVPlayerLayer` 嵌入窗口的 contentView
  - 支持循环播放（`AVPlayerLooper` 或监听播放结束事件）
  - 支持精确暂停/跳帧（`seek(to:)` 方法）
  - 支持淡入淡出（窗口 alpha 动画）

- 图片序列渲染：
  - 按文件名排序加载图片序列
  - 使用定时器按帧率切换 `NSImageView` 或 `CALayer.contents`
  - 支持暂停/跳帧

- 播放控制接口：
  - `play()`：开始循环播放
  - `pause()`：暂停在当前帧
  - `stepForward(frames:)`：向前跳指定帧数并暂停
  - `fadeOut(duration:completion:)`：渐隐并销毁窗口
  - `currentFrame: Int`：当前帧序号（视频需换算帧号）

#### 3.4 ConfigStore — 配置管理

- 职责：持久化存储用户配置
- 存储方案：`UserDefaults` + JSON 编码的 Codable 结构体
- 配置结构：

```
AppConfig {
    idleTimeoutMinutes: Double    // 闲置阈值 N
    microStepIntervalSeconds: Double  // 微跳间隔 Y
    microStepFrameCount: Int      // 微跳帧数 Z
    exitMode: ExitMode            // .immediate / .fadeOut
    briefEntryGraceSeconds: Double  // 鼠标短暂进入宽限期（秒，0 = 立即退出）
    wallpaperConfigMode: WallpaperConfigMode  // .allDisplays / .perDisplay
    sharedWallpaperType: WallpaperType        // 所有显示器模式下的共享类型
    sharedWallpaperAssetID: String            // 所有显示器模式下的共享素材 ID
    displayConfigs: [DisplayConfig]           // 逐显示器配置（含各显示器帧位置）
}

DisplayConfig {
    displayID: String             // 显示器唯一标识
    wallpaperType: WallpaperType  // .system / .video / .imageSequence（仅单独设置模式生效）
    wallpaperAssetID: String      // 素材 ID（仅单独设置模式生效）
    lastFramePosition: Int        // 上次退出帧位置（两种模式均按显示器独立记录）
}
```

- 壁纸解析规则：`wallpaperConfigMode == .allDisplays` 时所有显示器统一使用 `sharedWallpaperType` / `sharedWallpaperAssetID`（素材缺失时回退到该类型第一个可用素材）；`.perDisplay` 时各显示器使用自己的 `DisplayConfig`。
- 兼容性：`AppConfig` 自定义 `init(from:)`，旧版本持久化数据缺少新增字段时回退默认值（合成 Codable 对缺失键会抛错，不能依赖属性默认值）。

#### 3.5 AssetStore — 素材管理

- 职责：管理壁纸素材的导入、存储和索引
- 素材存储位置：`~/Library/Application Support/WallFlux/Assets/`
- 素材类型：
  - `SystemWallpaper`：枚举 macOS 系统自带动态壁纸路径
  - `VideoAsset`：用户导入的视频文件（复制到素材目录）
  - `ImageSequenceAsset`：用户导入的图片文件夹
- 元数据以 JSON 文件存储在素材目录中

#### 3.6 SmartPauseMonitor — 智能暂停监测

- 职责：聚合六个条件的实时状态，推送给 ScreenManager 应用到各显示器（设计文档：`docs/智能暂停与开机自启设计.md`）
- 条件与检测方式：
  - 系统睡眠：`NSWorkspace.willSleepNotification` / `didWakeNotification`；唤醒后先重置各屏为活跃（`handleSystemWake`）再恢复
  - 显示器睡眠：轮询 `CGDisplayIsAsleep`（每 2 秒，与全屏轮询共用定时器）。**注意**：实测部分环境下 `NSWorkspace.screensDidSleep/Wake` 与 `CGDisplayRegisterReconfigurationCallback` 均不触发，轮询是可靠兜底；重构回调保留作为事件驱动加速
  - 低电量模式：`NSProcessInfoPowerStateDidChange` 通知 + `isLowPowerModeEnabled`
  - 电池供电 / 电量百分比：`IOPSNotificationCreateRunLoopSource` 电源变化回调 + `IOPSCopyPowerSourcesInfo` 读取
  - 低电量阈值：暂停线 = 阈值，恢复线 = 阈值 + 5%（防抖滞后）；与是否插电无关
  - 全屏应用：每 2 秒轮询 `CGWindowListCopyWindowInfo`，layer 0 普通窗口 bounds 完全覆盖某屏 `visibleFrame` 即命中该屏（窗口坐标经 `appKitRectFromCGWindowList` 垂直翻转换算）；锁屏窗口（layer 2004）不命中
- 二值暂停模型：任一启用条件命中 → 完全暂停（停播放 + 停微跳），无降频中间态；总开关关闭时所有条件不评估
- 推送协议：`applySmartPause(globalReasons:fullscreenDisplayIDs:)`；`activeReasons`（@Published）供 UI 展示命中原因

#### 3.7 LaunchAtLogin — 开机自启

- 职责：系统登录项开关封装（设计文档 §1）
- 实现：`SMAppService.mainApp`（macOS 13+ 原生 API），**系统状态为真相源**，不在 AppConfig 冗余存布尔
- 关键能力：
  - `status` / `isEnabled`（enabled 与 requiresApproval 均视为开）/ `requiresApproval`
  - `enable()` → `register()`；`disable()` → `unregister()`；失败日志走 NSLog（stderr）
  - 首启弹窗：UserDefaults 标记 `WallFlux.didShowLaunchAtLoginPrompt`，只询问一次，默认不勾选；弹窗同时简述当前智能暂停命中状态
  - 开关组件 `LaunchAtLoginToggle`（面板紧凑模式 + 设置「启动」分区）：onAppear 读真实状态刷新，不做定时轮询；requiresApproval 时警示 + 「打开系统设置」（`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`）

### 4. 状态机

每个显示器的状态流转（`active` / `idle` / `exiting`，宽限为 idle 的子状态）：

```
        ┌──────────┐
        │  active   │ ← 用户在此显示器有输入
        │ (微跳中)  │
        └─────┬─────┘
              │ 闲置倒计时到期
              ▼
        ┌──────────┐
        │   idle    │ ← 开始循环播放壁纸（窗口置顶）
        │ (播放中)  │
        └─────┬─────┘
              │ 检测到用户输入（鼠标移至该屏/键盘操作）
              ▼
        ┌──────────────┐
        │ 宽限（子状态）│ ← 鼠标进入：壁纸降层让位并暂停
        │ (grace)       │     ├─ 宽限期内鼠标移出/停止移动 → 恢复置顶播放（回 idle）
        │               │     ├─ 点击/滚动/拖拽/键盘 → 立即退出
        │               │     └─ 持续移动满宽限期 → 恢复顶层后退出
        └──────┬───────┘
               │ 判定为真实使用
               ▼
        ┌──────────┐
        │  exiting  │ ← 执行退出动画（立即/渐隐）
        │ (退出中)  │
        └─────┬─────┘
              │ 退出完成，记录当前帧位置
              ▼
        ┌──────────┐
        │  active   │ ← 恢复微跳模式，从记录帧开始（窗口降回桌面层级）
        └──────────┘
```

### 5. 数据流

```
用户输入 (鼠标/键盘)
    │
    ▼
IdleDetector (CGEventTap)
    │
    ├── 鼠标纯移动（弱输入）→ 计算所在 NSScreen → 记录移入/移出，刷新宽限状态
    │       ├── 闲置显示器：启动宽限 → 壁纸降层让位 + 暂停
    │       │       ├── 移出/停止移动 → 恢复置顶播放
    │       │       └── 持续移动满宽限期 → 恢复顶层 → 渐隐退出
    │       └── 活跃显示器：重置闲置计时器
    ├── 鼠标点击/拖拽/滚动（强输入）→ 所在显示器立即标记活跃（不走宽限）
    └── 键盘事件 → AX 查询焦点窗口所在屏 → 标记活跃（不走宽限）
            └── AX 失败 → 回退鼠标所在屏 → 前台应用窗口 → 最后才回退全部
    │
    ▼
ScreenManager
    │
    ├── 某屏闲置计时器到期 → 切换为 idle
    │       └── WallpaperEngine.play() → 循环播放 + 窗口置顶（屏保层级）
    │
    ├── 某屏从 idle 变为活跃 → 切换为 exiting
    │       └── WallpaperEngine.fadeOut() or 立即停止
    │       └── 记录 currentFrame
    │
    └── 某屏进入 active（微跳）
            └── WallpaperEngine.pause() + 定时 stepForward()（窗口降回桌面层级）

智能暂停数据流：

```
SmartPauseMonitor（条件事件驱动 + 2 秒全屏/显示器睡眠轮询）
    │
    ├── 系统睡眠 willSleep / 显示器睡眠 CGDisplayIsAsleep / 低电量模式通知
    ├── 电源回调 IOPS（电池供电 / 电量百分比）→ 低电量阈值滞后评估
    └── 全屏轮询 CGWindowList → 命中显示器 ID 集合
    │
    ▼
applySmartPause(globalReasons ∪ fullscreenDisplayIDs)
    │
    ▼
ScreenContext.setSmartPauseReasons → isPaused = 手动 ∨ 智能
    │
    ├── 暂停：停 idle/微跳计时器、engine.pause()（窗口降回桌面层级）
    └── 恢复：active 恢复微跳；idle 从当前帧继续循环播放
    │
    ▼
UI（面板「已暂停：[原因]」+ 设置「当前已暂停」）← activeReasons
```
```

### 6. 关键 API / 框架依赖

| 用途 | API / 框架 |
|------|-----------|
| 显示器枚举与监听 | `NSScreen`, `didChangeScreenParametersNotification` |
| 桌面层级窗口 | `NSWindow`, `CGWindowLevelKey.desktopWindow` |
| 全局输入事件 | `CGEvent.tapCreate`, 辅助功能权限 |
| 视频播放 | `AVFoundation` (AVPlayer, AVPlayerLayer, AVPlayerLooper) |
| 图片序列 | `NSImage` + 定时器 |
| 窗口动画 | `NSAnimationContext` / `NSWindow.animator().alphaValue` |
| 开机自启 | `ServiceManagement` (`SMAppService.mainApp`) |
| 电源状态 | `IOKit.ps`（IOPS 通知 + 电量读取）、`ProcessInfo.isLowPowerModeEnabled` |
| 显示器睡眠 | `CGDisplayIsAsleep`（轮询）、`CGDisplayRegisterReconfigurationCallback`（加速） |
| 全屏检测 | `CGWindowListCopyWindowInfo`（layer 0 窗口覆盖工作区判定） |
| 持久化 | `UserDefaults` + JSONEncoder/JSONDecoder |

### 7. 权限要求

| 权限 | 用途 | 获取方式 |
|------|------|----------|
| 辅助功能权限 | 全局输入事件监控 | 引导用户至「系统设置 → 隐私与安全性 → 辅助功能」 |
| 文件访问权限 | 导入壁纸素材 | 使用 NSOpenPanel（无需额外权限） |

### 8. 风险与待确认事项

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 壁纸窗口层级（`kCGScreenSaverWindowLevel` / `kCGDesktopIconWindowLevel`）在 macOS 未来版本中行为变化 | 置顶/桌面层级可能不生效 | 预留降级方案（使用相邻的 CGWindowLevel 值），层级切换集中在 `WallpaperWindow.applyLevel` 便于调整 |
| CGEventTap 被系统终止 | 闲置检测失效 | 实现 tap 超时重连机制 |
| Mac App Store 沙盒限制 | 无法通过商店分发 | 仅通过 DMG / Homebrew 分发 |
| 多 Spaces 下窗口行为异常 | 壁纸窗口出现在错误桌面 | 设置 `stationary` + `canJoinAllSpaces` behavior |
| 显示器睡眠通知不可靠（部分系统 `screensDidSleep/Wake` 与 CGDisplay 重构回调不触发） | 显示器睡眠条件检测失效 | 轮询 `CGDisplayIsAsleep`（与全屏轮询共用 2 秒定时器），重构回调仅作事件驱动加速 |
| 锁屏窗口误判全屏应用 | 锁屏时全屏条件误命中 | 全屏检测仅匹配 layer 0 窗口，锁屏窗口（layer 2004）不命中 |
| 低电量阈值边界抖动 | 电量在阈值附近波动导致频繁暂停/恢复 | 恢复线 = 阈值 + 5% 防抖滞后，阈值与恢复线之间保持现状 |