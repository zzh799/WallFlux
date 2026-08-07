# 发布流程（Release）

WallFlux 的发布采用「本地一键脚本 + GitHub Actions 自动构建发布」的方式：`tools/release.sh` 在本地完成版本号、构建、安装、提交、打 tag、推送，并等待 CI 产出 Release 与 DMG；Homebrew cask 由 tap 仓库自动同步，全程无需手动上传产物。

## 快速上手

```bash
# 常用：递增 patch（1.5.1 -> 1.5.2）并发布，未提交的改动带上说明一并提交
tools/release.sh --bump patch -m "修复 xxx"

# 若代码已提交、仅需按当前版本发布
tools/release.sh

# 只做安全检查与流程演练，不修改任何文件
tools/release.sh --dry-run --bump patch
```

## 脚本做什么（一次完成八步）

| 步骤 | 说明 |
|------|------|
| 1. 版本号 | 读取 `WallFlux/Info.plist` 的 `CFBundleShortVersionString`；`--bump` 时按 semver 自动递增并同步写入 pbxproj 的 `MARKETING_VERSION` |
| 2. 前置检查 | 校验工具链存在、版本格式合法、目标 tag 未存在、工作区无未提交改动（或用 `-m` 自动提交） |
| 3. Release 构建 | `xcodebuild -configuration Release -derivedDataPath build`（与 CI 同一命令），并校验产物版本号与目标一致 |
| 4. 安装 | 退出运行中的 WallFlux，替换 `/Applications/WallFlux.app` 并校验版本 |
| 5. 提交 | 有未提交改动时按 `-m` 信息（或仅版本号改动时自动信息）`git commit` |
| 6. 打 tag | `git tag vX.Y.Z` 并推送 `main` 与 tag |
| 7. 等 CI | 轮询 GitHub Actions 的 `Release` workflow（release.yml），失败即中止并给出链接 |
| 8. 校验 | 确认 GitHub Release 已生成且含 `WallFlux-<版本>.dmg` 资产 |

## 参数

| 参数 | 作用 |
|------|------|
| `--bump patch\|minor\|major` | 递增版本号：`1.5.1` → `1.5.2` / `1.6.0` / `2.0.0` |
| `-m <信息>` | 自动提交工作区所有未提交改动（含测试与文档） |
| `--skip-install` | 不安装到 `/Applications`（仅 CI 验证用） |
| `--skip-wait` | 推送后不等待 CI，自行查看 Actions 结果 |
| `--dry-run` | 只检查环境与参数、打印将执行的操作，不产生任何修改 |

## 版本号约定

- **实际生效**：`WallFlux/Info.plist` 的 `CFBundleShortVersionString`（项目 `GENERATE_INFOPLIST_FILE = NO`，`MARKETING_VERSION` 不参与编译，仅保留一致）。
- 脚本 `--bump` 会同步修改两处；手动改版本时请保持两处一致（脚本不强制校验 pbxproj，仅以 Info.plist 为准）。
- tag 名固定为 `vX.Y.Z`，与 Info.plist 版本一一对应；同名 tag 已存在时脚本直接拒绝，防止误覆盖历史版本。

## 提交与安全策略

- 走 `-m` 时脚本 `git add -A && git commit`，一次性带上「代码 + 版本号 + 文档」。
- 无 `-m` 且工作区有**非版本号**改动时拒绝执行，避免把未说明的改动混进发布提交。
- 三道硬校验：tag 不重复、构建产物版本 == 目标版本、安装后版本 == 目标版本，任一不符即中止。

## CI 与发布链路（推送后自动进行）

| 环节 | 触发 | 产物 |
|------|------|------|
| `build.yml` | push main / PR | Debug 构建验证（CI 门禁） |
| `release.yml` | push `v*` tag | Release 构建 + DMG（含 Applications 软链）+ GitHub Release |
| `zzh799/homebrew-WallFlux` 的 `sync-cask.yml` | 每 30 分钟扫描新 Release | 下载 DMG 计算 sha256、更新 `Casks/wallflux.rb` |

用户侧安装命令不变：`brew install --cask zzzh799/wallflux/wallflux`（必须全小写）。

## 故障排查

| 现象 | 原因与处理 |
|------|-----------|
| `tag vX.Y.Z 已存在` | 该版本已发布过。补发代码请用 `--bump` 递增版本，不要删除/复用旧 tag |
| `工作区有未提交改动` | 先自行提交，或加 `-m "<说明>"` 让脚本代提交 |
| `构建产物版本与目标不一致` | 一般是忘了改版本号或本地有旧 build/ 缓存，先清 `build/` 或检查 Info.plist |
| Release workflow 失败 | 到 Actions 页面看日志；多为签名/打包环境问题，修复后重新 `git tag` 一个 ≥ 当前版本的新 tag |
| `Release 缺少 DMG 资产` | Actions 构建成功但上传失败，检查 release.yml 日志；可手动上传 DMG |
| 等待 CI 超时（10 分钟） | GitHub 队列繁忙；`--skip-wait` 先退出脚本，稍后自行查看 |
| cask 未更新 | cask 同步最长 30 分钟延迟，确认新 release 在 GitHub Release 页面可见即可 |

## 备注

- E2E 验证仍遵循：启动后看系统日志 `log stream --info --debug --predicate 'subsystem == "com.wallflux.WallFlux"'`。
- 发布无自动化测试框架依赖，构建通过 + 安装后手动验证即可。