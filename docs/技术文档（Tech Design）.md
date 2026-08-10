
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
│  │ Controller│  │   - 全局 / 屏保 / 壁纸设置  │  │
│  │ (SwiftUI) │  │   - 显示器壁纸设置（含素材管理分栏）   │  │
│  │          │  │   - 媒体应用               │  │
│  └────┬─────┘  └───────────┬──────────────┘  │
│       │                    │                  │
│  ┌────┴────────────────────┴──────────────┐   │
│  │           CoreManager                   │   │
│  │  - 显示器管理 (ScreenManager)           │   │
│  │  - 闲置检测 (IdleDetector)             │   │
│  │  - 配置管理 (ConfigStore)              │   │
│  │  - 素材管理 (AssetStore)               │   │
│  │  - 智能暂停监测 (SmartPauseMonitor)    │   │
│  │  - 媒体播放监测 (MediaPlaybackMonitor) │   │
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
    recentWallpapers: [RecentWallpaperUse]    // 最近使用壁纸（按使用时间倒序，上限 10）
}

RecentWallpaperUse {
    assetID: String               // 素材 ID
    type: WallpaperType           // 素材来源类型
    lastUsedAt: Date              // 最近一次使用时间
}

DisplayConfig {
    displayID: String             // 显示器唯一标识
    wallpaperType: WallpaperType  // .system / .screenSaver / .video / .imageSequence（仅单独设置模式生效）
    wallpaperAssetID: String      // 素材 ID（仅单独设置模式生效）
    lastFramePosition: Int        // 上次退出帧位置（两种模式均按显示器独立记录）
}
```

- 壁纸解析规则：`wallpaperConfigMode == .allDisplays` 时所有显示器统一使用 `sharedWallpaperType` / `sharedWallpaperAssetID`（素材缺失时回退到该类型第一个可用素材）；`.perDisplay` 时各显示器使用自己的 `DisplayConfig`。
- 最近使用壁纸：设置页选中素材（来源切换 / 素材选中 / Aerial 下载应用）与菜单栏面板「最近使用」快捷切换时记录（同素材去重置顶，上限 10）。面板快捷切换为「应用到所有显示器」语义：`.allDisplays` 写共享壁纸，`.perDisplay` 写各显示器独立配置（与显示器列表显示一致），两种模式均重置全部帧位置从头播放。
- 兼容性：`AppConfig` 自定义 `init(from:)`，旧版本持久化数据缺少新增字段时回退默认值（合成 Codable 对缺失键会抛错，不能依赖属性默认值）。

#### 3.5 AssetStore — 素材管理

- 职责：管理壁纸素材的导入、存储、索引，以及系统 Aerial 屏保视频的扫描与下载
- 素材存储位置：`~/Library/Application Support/WallFlux/Assets/`
- 素材类型：
  - `SystemWallpaper`：枚举 macOS 系统自带动态壁纸路径
  - `ScreenSaverWallpaper`：系统 Aerial 屏保已下载视频（**只读引用系统目录，不复制**）
  - `VideoAsset`：用户导入的视频文件（复制到素材目录；Aerial 下载到素材库的视频同属此类，可删除）
  - `ImageSequenceAsset`：用户导入的图片文件夹
- 元数据以 JSON 文件存储在素材目录中
- **系统 Aerial 屏保接入**（对应「系统屏保」壁纸来源）：
  - 扫描：`/Library/Application Support/com.apple.idleassetsd/Customer/` 下各分辨率子目录（`4KSDR240FPS` 等）的 `.mov`，文件名即资产 UUID；目录只读，WallFlux 只引用不写入
  - 目录清单：优先 `Customer/entries.json`（与实际下载对账），缺失时回退系统内置清单 `TVIdleServices.framework/.../entries.json`（137 个资产，离线可用）；资产含 `url-4K-SDR-240FPS`（Apple CDN 直链）与 `previewImage`
  - 本地化：`TVIdleScreenStrings.bundle` 的 `Localizable.nocache.loctable`（按当前系统语言取表，zh 优先 `zh_CN`），解析资产名/分类名；loctable 为嵌套 NSDictionary，需逐层桥接转型
  - 下载：`downloadAerialItem(id:)` 用 `URLSession.downloadTask` 从 CDN 下载到素材库（`aerial-<UUID>/`），KVO 监听 `task.progress.fractionCompleted` 发布进度；完成后按 `VideoAsset` 登记（可删除），`cancelAerialDownload(id:)` 取消并清理
  - 系统已下载与素材库下载的映射：`aerialAsset(for:)` 优先系统引用（`screensaver:<UUID>`），其次素材库（`aerial-<UUID>`）
  - 删除规则：`system` 与 `screenSaver` 均只读不可删；Aerial 下载到素材库的视频可删（删除时被使用则先回退到视频分类第一个可用素材）

#### 3.6 SmartPauseMonitor — 智能暂停监测

- 职责：聚合五个全局条件的实时状态，推送给 ScreenManager 应用到所有显示器（设计文档：`docs/智能暂停与开机自启设计.md`）。全屏检测不属于全局条件：作为微跳模式的独立行为单独推送
- 条件与检测方式：
  - 系统睡眠：`NSWorkspace.willSleepNotification` / `didWakeNotification`；唤醒后先重置各屏为活跃（`handleSystemWake`）再恢复
  - 显示器睡眠：2 秒轮询 `CGDisplayIsAsleep`（与窗口轮询共用同一 2 秒定时器）。**注意**：实测部分环境下 `NSWorkspace.screensDidSleep/Wake` 与 `CGDisplayRegisterReconfigurationCallback` 均不触发，轮询是可靠兜底；重构回调保留作为事件驱动加速
  - 低电量模式：`NSProcessInfoPowerStateDidChange` 通知 + `isLowPowerModeEnabled`
  - 电池供电 / 电量百分比：`IOPSNotificationCreateRunLoopSource` 电源变化回调 + `IOPSCopyPowerSourcesInfo` 读取
  - 低电量阈值：暂停线 = 阈值，恢复线 = 阈值 + 5%（防抖滞后）；与是否插电无关
  - 全屏应用（微跳模式行为，非智能暂停）：每 2 秒轮询 `CGWindowListCopyWindowInfo`，layer 0 普通窗口 bounds 完全覆盖某屏 `visibleFrame` 即命中该屏（窗口坐标经 `appKitRectFromCGWindowList` 垂直翻转换算）；锁屏窗口（layer 2004）不命中。命中仅用于在活跃屏暂停微跳，闲置屏照常循环播放
- 二值暂停模型：任一启用条件命中 → 完全暂停（停播放 + 停微跳），无降频中间态；总开关关闭时所有全局条件不再评估
- 推送协议：`applySmartPause(globalReasons:)` 与 `applyFullscreenDisplayIDs(_:)` 两路推送；`activeReasons`（@Published）只包含智能暂停条件，供 UI 展示命中原因

#### 3.7 LaunchAtLogin — 开机自启

- 职责：系统登录项开关封装（设计文档 §1）
- 实现：`SMAppService.mainApp`（macOS 13+ 原生 API），**系统状态为真相源**，不在 AppConfig 冗余存布尔
- 关键能力：
  - `status` / `isEnabled`（enabled 与 requiresApproval 均视为开）/ `requiresApproval`
  - `enable()` → `register()`；`disable()` → `unregister()`；失败日志走 NSLog（stderr）
  - 首启弹窗：UserDefaults 标记 `WallFlux.didShowLaunchAtLoginPrompt`，只询问一次，默认不勾选；弹窗同时简述当前智能暂停命中状态
  - 开关组件 `LaunchAtLoginToggle`（面板紧凑模式 + 设置「启动」分区）：onAppear 读真实状态刷新，不做定时轮询；requiresApproval 时警示 + 「打开系统设置」（`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`）

#### 3.8 MediaPlaybackMonitor — 媒体播放监测

- 职责：监测其他应用（Chrome/Safari 网页视频、直播、播放器、音乐等）是否正在输出声音（FR-16），命中显示器不进入闲置循环播放，避免壁纸覆盖播放内容；不影响微跳（与全屏暂停微跳是两个独立行为）
- 查询机制（CoreAudio 进程级公开 API，方案 B'，参考 sountop，MIT）：
  - 枚举 `kAudioHardwarePropertyProcessObjectList`（系统对象）得全部音频客户端进程对象；逐个查 `kAudioProcessPropertyIsRunningOutput`（是否正在出声）、`kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID`（进程身份）
  - 100% 公开 API、零授权、macOS 14 即可用，不再依赖私有 MediaRemote 与第三方 dylib；局限：`IsRunningOutput` 只证明输出 IO 在跑，不保证非静音（静音流也算出声），对「防闲置」足够
  - 进程筛选：排除音频驱动等系统基础设施（bundle ID 前缀 `com.apple.audio.`）；显示名优先 `NSRunningApplication.localizedName`，渲染/音频子进程（如 Chrome 的 `com.google.Chrome.helper`）按可执行路径（`proc_pidpath`）定位所属 App 包后归到宿主应用名
- 忽略名单：设置「媒体应用」页（最后一个 tab）逐应用开关；国内外常见音乐应用预置只读白名单（`MediaAppWhitelist`，纯音乐/音频应用，不含视频/直播类），不在主列表展示、不预先占用忽略名单——应用真实播放过声音后自动写入忽略名单（`mediaPlaybackMonitor.applyAutoIgnore`；用户手动关闭过的键写入 `mediaWhitelistUserExcludedKeys`，不再自动重新加入）；被忽略应用即使正在出声也不命中（命中计算直接排除），切换后立即重新评估放行；忽略名单与发现历史（bundle ID → 名称 + 最近播放时间）持久化在 ConfigStore（UserDefaults），重启不丢；发现历史始终累积，与开关无关，白名单在「媒体应用」页右下角弹窗只读查看
- 轮询与推送：
  - 2 秒定时器（与 SmartPauseMonitor 同节奏），枚举在后台队列执行（单轮仅数十个属性查询，开销可忽略）；上一轮在途时跳过本轮
  - 命中计算：`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 取出声进程 layer 0 普通窗口，与各 `NSScreen.frame`（同为 CGWindowList 全局显示坐标）判交得命中屏集合；任一出声进程找不到窗口（后台播放、Safari 的 WebKit 子进程播放、Chrome 音频服务进程等）时回退命中所有显示器（保守）
  - 推送 `applyMediaPlaybackDisplayIDs(_:)`；配置开关 `mediaPlaybackKeepsActive` 关闭时不命中、立即清空命中（发现历史与「正在播放」列表照常维护）
- 状态机联动（见 §4）：
  - `active`：媒体播放中不启用闲置计时（媒体结束后 `setMediaPlaybackPresent(false)` 重新启动）；媒体开始时若该屏正闲置播放则立即 `beginExit` 让位
  - `idleTimerFired` / `resetIdleTimer` 均带 `mediaPlaybackBlocksIdle` 守卫（自动闲置）；`forcePlayNow`（立即播放，FR-12）为用户显式操作，强制覆盖媒体守卫：预览期间置顶播放且媒体守卫不生效（`manualPreviewActive`），任意输入退出后恢复守卫
  - 暂停（手动/智能）期间不处理媒体变化，恢复时由 `applyResume` 走守卫
### 4. 状态机

每个显示器的状态流转（`active` / `idle` / `exiting`，宽限为 idle 的子状态）：

媒体播放保持活跃（FR-16）不改变状态机形状，只加两条边：
- active 时媒体播放中 → 不启动闲置计时（无状态迁移）；媒体结束后重新启动闲置计时
- idle 时媒体开始播放 → 立即走 exiting 退出（壁纸让位，与用户输入退出同路径）

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
SmartPauseMonitor（条件事件驱动 + 2 秒窗口/显示器睡眠轮询）
    │
    ├── 系统睡眠 willSleep / 显示器睡眠 CGDisplayIsAsleep / 低电量模式通知
    ├── 电源回调 IOPS（电池供电 / 电量百分比）→ 低电量阈值滞后评估
    └── 窗口轮询 CGWindowList → 命中显示器 ID 集合（微跳暂停用）
    │
    ▼
applySmartPause(globalReasons:) + applyFullscreenDisplayIDs(displayIDs)
    │
    ▼
ScreenContext.setFullscreenPresent → 命中屏仅在活跃时暂停微跳（闲置播放不受影响）
ScreenContext.setSmartPauseReasons → isPaused = 手动 ∨ 智能
    │
    ├── 暂停：停 idle/微跳计时器、engine.pause()（窗口降回桌面层级）
    └── 恢复：active 恢复微跳；idle 从当前帧继续循环播放
    │
    ▼
UI（面板「已暂停：[原因]」+ 设置「当前已暂停」）← activeReasons
```

媒体播放数据流：

```
MediaPlaybackMonitor（2 秒轮询）
    │  CoreAudio 进程级公开 API（方案 B'）
    │  kAudioHardwarePropertyProcessObjectList 枚举 + kAudioProcessPropertyIsRunningOutput
    │  → 正在出声的进程（PID / BundleID / 名称），排除 com.apple.audio.* 与忽略名单
    ▼
命中计算：出声进程 layer0 窗口 ∩ NSScreen.frame → 命中屏集合
          （任一进程无窗口时回退所有显示器）
    │
    ▼
applyMediaPlaybackDisplayIDs(displayIDs)
    │
    ▼
ScreenContext.setMediaPlaybackPresent
    │   ├── active：媒体播放中不启闲置计时（结束后恢复）
    │   └── idle：媒体开始播放 → beginExit（壁纸让位）
    ▼
idleTimerFired / resetIdleTimer 均带 mediaPlaybackBlocksIdle 守卫（自动闲置）；
forcePlayNow（立即播放）为用户显式操作，强制覆盖媒体守卫，预览期间媒体守卫不生效，任意输入退出后恢复
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
| 显示器睡眠通知不可靠（部分系统 `screensDidSleep/Wake` 与 CGDisplay 重构回调不触发） | 显示器睡眠条件检测失效 | 轮询 `CGDisplayIsAsleep`（与窗口轮询共用 2 秒定时器），重构回调仅作事件驱动加速 |
| 锁屏窗口误判全屏应用 | 锁屏时误判有全屏应用（活跃屏暂停微跳） | 全屏检测仅匹配 layer 0 窗口，锁屏窗口（layer 2004）不命中 |
| 低电量阈值边界抖动 | 电量在阈值附近波动导致频繁暂停/恢复 | 恢复线 = 阈值 + 5% 防抖滞后，阈值与恢复线之间保持现状 |
| 声音意外/静音流误判 | `IsRunningOutput` 只证明输出 IO 在跑，静音流、系统提示音也算「正在出声」 | 对「防闲置」足够；被误判的应用可在「媒体应用」页单独忽略，或关闭总开关回归原状 |
| 出声进程找不到窗口 | 无法定位媒体位置（后台播放、浏览器渲染子进程等） | 回退命中所有显示器（保守）；后续可考虑按 Bundle 归属解析宿主窗口 |
| 系统音频基础设施进程干扰 | 音频驱动（bundle ID 前缀 `com.apple.audio.`）可能长期显示在出声列表 | 检测时直接排除该类进程；启动时清理历史中已排除的残留记录 |