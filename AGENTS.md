# AGENTS.md

本文件帮助 AI 编程助手在 WallFlux 代码库中高效工作。

## 项目概况

- **产品**：WallFlux —— macOS 14+（Sonoma）菜单栏常驻应用，为每个显示器独立配置动态壁纸；闲置显示器自动循环播放壁纸保护屏幕，活跃显示器进入"微跳"模式防烧屏。
- **仓库**：公开于 GitHub `zzh799/WallFlux`（https://github.com/zzh799/WallFlux），main 分支直接对接 GitHub Actions。
- **当前状态**：功能已完整实现（WallFlux/ 源码 + WallFlux.xcodeproj），CI（构建验证 + 自动发布）已就绪。写代码前先读文档。

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
- 底层窗口：AppKit（`NSWindow`、`NSScreen`、`kCGScreenSaverWindowLevel`）
- 系统壁纸：`NSWorkspace.setDesktopImageURL`（活跃态桌面呈现，不创建窗口）
- 视频播放：AVFoundation（`AVPlayer`、`AVPlayerLayer`、`AVPlayerLooper`）
- 图片序列：`NSImage` / `CALayer` + 定时器
- 输入监控：`CGEventTap`（**需要辅助功能权限**）
- 持久化：`UserDefaults` + Codable JSON
- 分发：DMG + Homebrew Cask（**不走 Mac App Store**，沙盒限制）；tap 仓库为 `zzh799/homebrew-WallFlux`（`Casks/wallflux.rb`）

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
- 素材存放 `~/Library/Application Support/WallFlux/Assets/`，元数据以 JSON 存同目录。
- UI 遵守设计规范的 token（`spacing.*`、语义色），优先系统语义 API（`.title2`、`Color.accentColor`、`.monospacedDigit()` 等）。

## 已知坑（务必遵守）

- **CGEventTap 会被系统终止**：必须实现 tap 重连机制；首次使用需引导用户授予辅助功能权限。
- **`kCGScreenSaverWindowLevel`（闲置置顶播放）未来版本可能失效**：预留降级方案（改用相邻 CGWindowLevel）；活跃态不依赖窗口层级（系统壁纸 API）。
- **多 Spaces**：壁纸窗口必须设 `collectionBehavior = [.canJoinAllSpaces, .stationary]`。
- 壁纸窗口需 `ignoresMouseEvents = true`，背景色黑色兜底（视频未加载时）。
- 壁纸窗口默认隐藏，仅闲置置顶播放时显示（`kCGScreenSaverWindowLevel`）；活跃态壁纸直接设为系统壁纸；系统壁纸 API 同一 URL 不刷新，每帧须写新文件名。
- 键盘输入通过 AX 查询聚焦窗口定位所在屏幕（`IdleDetector.focusedDisplayID()`），查询失败（系统繁忙 `kAXErrorCannotComplete` 等）时逐级回退：鼠标位置 → 前台应用窗口（`frontmostWindowDisplayID()`，CGWindowList）→ 最后才回退所有屏幕活跃，避免无输入屏幕的闲置计时器被反复重置。
- `os.Logger` 的 `info` 级别日志需 `log show/stream --info --debug` 才能看到（默认被过滤）。
- swift 脚本（swift-frontend 解释执行）的 `os.Logger` 不生效，测试脚本用 `NSLog` 或编译后运行。

## CI 与发布

- 工作流位于 `.github/workflows/`：
  - `build.yml`：push main / PR 时构建 Debug 验证，作为 CI 门禁。
  - `release.yml`：推送 `v*` 标签时构建 Release、打包 DMG（含 Applications 软链）并自动发布 GitHub Release；产物含 `WallFlux-<版本>.dmg`。
- **用户说「发布新版本」时，直接执行 `tools/release.sh`**（不手动拆步骤）：先确认是否需 `--bump patch|minor|major`（按改动幅度，拿不准就问用户）；有未提交改动且用户未给提交信息时用 `-m "<变更摘要>"` 让脚本代提交；其余参数默认（构建、安装到 /Applications、打 tag、推送、等 CI 产 DMG）。脚本含 tag 冲突、产物版本、安装版本三道硬校验。完整用法与故障排查见 [docs/发布流程（Release）.md](docs/发布流程（Release）.md)。
- Homebrew cask 由 tap 仓库（`zzh799/homebrew-WallFlux`）的 `sync-cask.yml` 每 30 分钟自动同步：检测到新 Release 后下载 DMG 计算 sha256 并更新 cask，无需手动维护。安装命令：`brew install --cask zzh799/wallflux/wallflux`（Homebrew 对 tap/cask 名大小写敏感，必须全小写）。
- 中英文用户文档为 `README.md`（英文）与 `README_zh.md`（中文），修改产品行为时同步更新。

## 构建与运行

```bash
# 构建（Debug）
xcodebuild -project WallFlux.xcodeproj -scheme WallFlux -configuration Debug -derivedDataPath build build

# 运行
./build/Build/Products/Debug/WallFlux.app/Contents/MacOS/WallFlux
# 或 open ./build/Build/Products/Debug/WallFlux.app

# 查看应用日志（需 --info 才能看到 info 级别）
log stream --info --debug --predicate 'subsystem == "com.wallflux.WallFlux"'
log show --last 10m --info --debug --predicate 'subsystem == "com.wallflux.WallFlux"'

# 构建（Release，与 CI 一致）
xcodebuild -project WallFlux.xcodeproj -scheme WallFlux -configuration Release -derivedDataPath build build

# 调试配置注入（写入 defaults 域，二进制 plist 包 JSON Data）
# 见 tools/write_test_config.swift 思路：PropertyListSerialization 包装后 defaults import
```

- 无自动化测试框架；E2E 验证方式：启动后 `screencapture` 对比帧差异、`log show` 查状态转换。
- 无 storyboard：入口为 `main.swift`（显式 `NSApplication` + delegate），不要改回 `@main`。
