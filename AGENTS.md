# AGENTS.md

本文件帮助 AI 编程助手在 WallFlux 代码库中高效工作。

## 项目概况

- **产品**：WallFlunx —— macOS 14+（Sonoma）菜单栏常驻应用，为每个显示器独立配置动态壁纸；闲置显示器自动循环播放壁纸保护屏幕，活跃显示器进入"微跳"模式防烧屏。
- **当前状态**：**文档驱动阶段** —— 仓库仅含 `docs/`，尚无 Xcode 工程与源码。写任何代码前先读文档。

## 文档即规范（先读后写）

| 文档 | 内容 | 何时查阅 |
|------|------|----------|
| [docs/需求文档（PRD）.md](docs/需求文档（PRD）.md) | 功能需求 FR-01~FR-13、非功能需求 NFR-01~05 | 实现功能前核对需求编号，确保覆盖 |
| [docs/技术文档（Tech Design）.md](docs/技术文档（Tech Design）.md) | 架构分层、模块职责、状态机、数据流、关键 API、风险 | 新增/修改任何模块时严格对齐 |
| [docs/设计规范.md](docs/设计规范.md) | 色彩/字体/间距 token、组件规范、动效、无障碍 | 所有 UI 实现（菜单栏面板、设置窗口） |

不要复制文档内容进代码注释，用文档链接引用。

## 技术栈

- 语言：Swift 5.9+，Xcode 15+
- UI：SwiftUI（菜单栏面板 + 设置窗口）
- 底层窗口：AppKit（`NSWindow`、`NSScreen`、`kCGDesktopWindowLevel`）
- 视频播放：AVFoundation（`AVPlayer`、`AVPlayerLayer`、`AVPlayerLooper`）
- 图片序列：`NSImage` / `CALayer` + 定时器
- 输入监控：`CGEventTap`（**需要辅助功能权限**）
- 持久化：`UserDefaults` + Codable JSON
- 分发：DMG + Homebrew Cask（**不走 Mac App Store**，沙盒限制）

## 架构分层

```
MenuBarApp / SettingsWindow (SwiftUI)
        ↓
CoreManager ── ScreenManager / IdleDetector / ConfigStore / AssetStore
        ↓
WallpaperEngine（壁纸窗口创建、视频/图片序列渲染、播放控制）
```

- 每个显示器一个 `ScreenContext`，用 `NSScreen.displayID` 唯一标识，热插拔时按 ID 恢复配置。
- 显示器状态机：`active`（微跳）→ `idle`（循环播放）→ `exiting`（退出动画）→ `active`。
- 配置结构 `AppConfig` / `DisplayConfig`、状态机与数据流见技术文档 §3.4 / §4 / §5。

## 约定

- 注释、提交信息、UI 文案使用**中文**；代码标识符用英文。
- 模块/类型命名对齐技术文档：`CoreManager`、`ScreenManager`、`IdleDetector`、`ConfigStore`、`AssetStore`、`WallpaperEngine`、`ScreenContext`。
- 播放控制接口：`play()` / `pause()` / `stepForward(frames:)` / `fadeOut(duration:completion:)` / `currentFrame`。
- 素材存放 `~/Library/Application Support/WallFlunx/Assets/`，元数据以 JSON 存同目录。
- UI 遵守设计规范的 token（`spacing.*`、语义色），优先系统语义 API（`.title2`、`Color.accentColor`、`.monospacedDigit()` 等）。

## 已知坑（务必遵守）

- **CGEventTap 会被系统终止**：必须实现 tap 重连机制；首次使用需引导用户授予辅助功能权限。
- **`kCGDesktopWindowLevel` 未来版本可能失效**：预留降级方案（改用更低 CGWindowLevel）。
- **多 Spaces**：壁纸窗口必须设 `collectionBehavior = [.canJoinAllSpaces, .stationary]`。
- 壁纸窗口需 `ignoresMouseEvents = true`，背景色黑色兜底（视频未加载时）。
- 仓库暂无 `.gitignore`，且 `docs/设计规范.md` 尚未纳入 git 跟踪——提交前注意补上。

## 构建与状态

- 目前**没有** `.xcodeproj` / `Package.swift`。首次创建工程时按技术文档生成模块结构，并补齐 `.gitignore`。
- 创建工程后，请回填本文件：补充构建/测试/运行命令与 `xcodebuild` 用法。
