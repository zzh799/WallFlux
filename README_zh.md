# WallFlux

> 为每个显示器独立配置动态壁纸。

WallFlux 是一款 macOS 14+（Sonoma 及以上）菜单栏常驻应用，能为每台显示器独立配置动态壁纸：闲置的显示器自动循环播放动态壁纸以保护屏幕，活跃的显示器则进入几乎不可察觉的「微跳」模式以避免烧屏，全程不打扰你的工作。

[English](README.md) | 简体中文

## 功能特性

- **逐显示器独立配置** - 每台显示器可选用不同壁纸，通过硬件 ID 记忆配置，插拔后自动恢复；也可选择「所有显示器」统一壁纸，新接入的显示器自动沿用
- **智能闲置检测** - 全局鼠标 + 键盘输入监控；某显示器超过 N 分钟（默认 1 分钟，可配置）无输入即自动开始播放动态壁纸
- **微跳防烧屏** - 活跃显示器上的壁纸保持暂停，每 Y 秒向前跳 Z 帧，视觉上静止不动，却能有效防止 OLED 烧屏
- **四种壁纸来源** - macOS 系统自带动态壁纸、系统屏保（Aerial 航拍视频，直接引用系统已下载文件）、本地视频文件（mp4 / mov / webm）、本地图片序列（按文件名排序的图片文件夹）
- **优雅退出** - 回到工位时壁纸按配置退出：立即停止或渐隐过渡（默认 0.5 秒淡出）；鼠标短暂经过播放中的显示器不会打断壁纸，移出或停止移动即恢复置顶播放
- **立即预览** - 设置窗口「立即播放动态壁纸」，无需等闲置超时即可全屏预览当前壁纸；任意鼠标移动或键盘输入即退出，闲置切换壁纸时自动继续播放
- **屏保级置顶播放** - 播放期间壁纸窗口置于最顶层（屏保层级），类似屏保效果；鼠标进入时立即让位降回桌面层级，不遮挡工作窗口
- **热插拔支持** - 自动检测显示器连接 / 断开，重新接入时恢复之前配置
- **智能暂停** - 任一启用条件命中（系统睡眠 / 显示器睡眠 / 低电量模式 / 电池供电 / 电量低于阈值（带 +5% 恢复滞后））即完全暂停壁纸播放与微跳；手动暂停与智能暂停相互独立、任一命中即暂停；另外全屏或最大化应用窗口所在屏不微跳（不影响闲置屏的屏保播放）
- **媒体感知闲置** - 其他应用正在播放媒体时（Chrome / Safari 网页视频、直播、播放器、音乐等，音频视频一律算），播放所在显示器保持活跃、不进入闲置循环播放，壁纸不会覆盖你正在看的内容；已暂停的媒体不触发，播放停止后恢复闲置检测。该屏微跳照常进行，可在设置中关闭
- **开机自启** - 默认关闭，首启弹窗询问是否登录时自动启动；菜单栏面板与设置中的开关以系统状态为准双向同步

## 系统要求

- macOS 14.0+（Sonoma 及以上）
- Apple Silicon 或 Intel

## 安装方式

### Homebrew 安装

```bash
brew install --cask zzh799/wallflux/wallflux
```

cask 会随每次发布自动同步更新。

### 手动安装（DMG）

从 [Releases 页面](https://github.com/zzh799/WallFlux/releases) 下载最新 DMG，打开后将 WallFlux.app 拖入「应用程序」文件夹。

### 源码构建

需要 Xcode 15+：

```bash
xcodebuild -project WallFlux.xcodeproj -scheme WallFlux -configuration Release -derivedDataPath build build
open ./build/Build/Products/Release/WallFlux.app
```

## 快速上手

1. 启动 WallFlux，它会常驻在菜单栏（⌘ 图标）。
2. 按提示授予**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能）。WallFlux 需要它来监控全局输入事件，以判断每台显示器是否闲置。
3. 点击菜单栏面板 → 设置，选择「所有显示器」统一壁纸，或切到「单独设置」为每台显示器分别选择壁纸（系统壁纸 / 系统屏保 / 视频 / 图片序列）。
4. 「系统屏保」来源直接引用系统 Aerial 屏保已下载的视频（共用同一文件，不重复占空间）；未下载的可在「打开下载中心」从 Apple CDN 下载，或「在系统设置中启用」后由系统自动下载。
5. 离开工位即可：闲置显示器自动开始播放；回来时壁纸淡出，恢复桌面。

## 工作原理

每台显示器运行一个状态机：

```
active（微跳） ── 闲置超时 ──▶ idle（循环播放壁纸，置顶）
      ▲                            │
      │                   鼠标进入：壁纸降层让位，进入宽限
      │                            │
      │              ┌───── 移出/停止移动 → 恢复置顶播放
      │              │
      │              └───── 持续移动满宽限期 → 退出
      └── 退出 ── exiting（退出动画）┘
```

- **闲置检测**基于全局 `CGEventTap`：鼠标所在显示器始终视为活跃；键盘输入以焦点窗口所在显示器为准。
- **短暂进入宽限**（默认 5 秒，可在设置中调整）：鼠标进入播放中的显示器时壁纸立即降层让位并暂停，宽限期内鼠标移出或停止移动则恢复置顶播放；点击/滚动/键盘等强交互立即退出。
- **微跳模式**将壁纸暂停在最后一帧，每 Y 秒向前跳 Z 帧再立即暂停：画面看似静止，实际不会长时间停留同一像素，实现防烧屏。
- 壁纸窗口**播放时置于顶层**（屏保层级 `kCGScreenSaverWindowLevel`），暂停/微跳时回到桌面图标层级（`kCGDesktopIconWindowLevel`），跟随所有 Spaces，且不拦截鼠标事件。

完整架构、数据流与状态机细节见 [docs/技术文档（Tech Design）.md](docs/技术文档（Tech Design）.md)。

## 文档

- [需求文档（PRD）](docs/需求文档（PRD）.md) - 功能与非功能需求（FR-01 ~ FR-16、NFR-01 ~ NFR-07）
- [技术文档（Tech Design）](docs/技术文档（Tech Design）.md) - 架构分层、模块职责、状态机、数据流
- [设计规范](docs/设计规范.md) - 设计 token 与组件规范

## 开源协议

WallFlux 采用 [GNU General Public License v3.0](LICENSE)。

应用打包了 [kirtan-shah/nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli)（同为 GPL-3.0）的 `mediaremote-mini.pl` 与 `MediaRemoteMini.dylib`，用于通过 MediaRemote 读取系统「正在播放」信息——详见 [WallFlux/Resources/MediaRemote/README.md](WallFlux/Resources/MediaRemote/README.md)。

## 项目结构

```
WallFlux/
├── App/       # main.swift 入口、AppDelegate、MenuBarController
├── Core/      # CoreManager、ScreenManager、IdleDetector、ConfigStore、AssetStore、Models
├── Engine/    # WallpaperEngine、WallpaperWindow、ImageSequenceRenderer
└── UI/        # SwiftUI 菜单栏面板与设置界面
```

## 常见问题

- **闲置检测失效** - macOS 可能终止 `CGEventTap`（已知系统行为）。WallFlux 会自动重连；若持续失效，请在系统设置中重新授予辅助功能权限。
- **壁纸不显示** - 请确认当前 macOS 版本下桌面窗口层级正常；未来 macOS 版本可能改变 `kCGDesktopWindowLevel` 行为，WallFlux 预留了降级层级方案。
