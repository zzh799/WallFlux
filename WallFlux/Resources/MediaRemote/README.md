# MediaRemote 辅助组件（第三方，GPL-3.0）

本目录包含从 [kirtan-shah/nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli)
（commit `8c8c1fa482`）引入的媒体播放状态查询组件，供 WallFlux 的
`MediaPlaybackMonitor` 使用：WallFlux 以 `/usr/bin/perl` 启动
`mediaremote-mini.pl` 加载 `MediaRemoteMini.dylib`，借助系统 perl 的 Apple
签名 entitlement 读取「正在播放」信息（详情见技术文档 §3）。

文件说明：

| 文件 | 说明 |
|------|------|
| `mediaremote-mini.pl` | perl 加载器（原仓库 `scripts/mediaremote-mini.pl`，未修改） |
| `MediaRemoteMini.dylib` | MediaRemote 查询适配层（由原仓库 `src/mediaremote-mini/` 源码构建，未修改；额外构建为 arm64 + x86_64 通用二进制） |
| `LICENSE` | GPL-3.0 许可证全文（原仓库 LICENSE） |

构建方式（与原仓库 `Makefile` 一致，仅增加双架构）：

```bash
clang -dynamiclib -fobjc-arc -fvisibility=default -O3 \
  -I src/mediaremote-mini/include -I src/mediaremote-mini \
  -arch arm64 -arch x86_64 \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -o MediaRemoteMini.dylib \
  src/mediaremote-mini/adapter/env.m \
  src/mediaremote-mini/adapter/get.m \
  src/mediaremote-mini/adapter/globals.m \
  src/mediaremote-mini/adapter/keys.m \
  src/mediaremote-mini/adapter/now_playing.m \
  src/mediaremote-mini/private/MediaRemote.m \
  src/mediaremote-mini/utility/helpers.m
codesign --force --sign - MediaRemoteMini.dylib
```

调用约定：`perl mediaremote-mini.pl <dylib绝对路径> adapter_get_env`，
stdout 输出单行 JSON（`playing` / `bundleIdentifier` / `processIdentifier` /
`title` 等）；无正在播放媒体时输出 `null`。注意 perl 为 hardened runtime，
dylib 路径必须为绝对路径。

WallFlux 整体采用 GPL-3.0 许可证，与本组件的许可证兼容。
