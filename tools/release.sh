#!/bin/bash
# macOS 自带 bash 3.2 在 UTF-8 locale 下与 set -u 组合存在多字节字解析 bug（误报 unbound variable）。
# 强制 C locale 规避；中文字符串仍按字节原样输出，不受影响。
export LC_ALL=C
# ============================================================
# WallFlux 发布脚本：一次完成
#   1. 版本号处理（可选自动递增）
#   2. Release 构建（与 CI 相同命令）
#   3. 安装到 /Applications
#   4. 提交 + 打 tag vX.Y.Z + 推送
#   5. 等待 GitHub Actions 生成 Release，校验 DMG 资产
#
# 完整说明见 docs/发布流程（Release）.md
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="WallFlux.xcodeproj"
SCHEME="WallFlux"
BUILD_DIR="build"
APP_SRC="$BUILD_DIR/Build/Products/Release/WallFlux.app"
APP_DST="/Applications/WallFlux.app"
INFO_PLIST="WallFlux/Info.plist"
PBXPROJ="$PROJECT/project.pbxproj"
# 版本信息落点：Info.plist 实际生效（GENERATE_INFOPLIST_FILE = NO），
# pbxproj 的 MARKETING_VERSION 仅保持同步一致
VERSION_FILES=("WallFlux/Info.plist" "WallFlux.xcodeproj/project.pbxproj")
GH_REPO="$(git config --get remote.origin.url | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
[ -n "$GH_REPO" ] || GH_REPO="zzh799/WallFlux"

# ---------- 选项 ----------
BUMP_KIND=""
COMMIT_MSG=""
INSTALL_APP=1
WAIT_CI=1
DRY_RUN=0

usage() {
    cat <<'EOF'
用法: tools/release.sh [选项]

选项:
  --bump <patch|minor|major>  发布前自动递增版本号（Info.plist 与 pbxproj 同步）
  -m <信息>                   工作区有未提交改动时，用该信息自动 git 提交
                              （仅有版本号改动时可不传，脚本自动提交"版本号 vX.Y.Z"）
  --skip-install              不安装到 /Applications（仅发布用）
  --skip-wait                 推送后不等待 CI（自行查看 Actions 结果）
  --dry-run                   只检查环境与参数，不执行任何修改/构建/推送
  -h, --help                  显示本帮助

示例:
  tools/release.sh                          # 按当前 Info.plist 版本直接发布
  tools/release.sh --bump patch -m "修复 xxx"  # 版本 1.5.1 -> 1.5.2 并发布
EOF
}

log() { printf '\033[36m[release]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[release] 错误：%s\033[0m\n' "$*" >&2; exit 1; }
run() { # dry-run 只打印，否则真实执行
    if (( DRY_RUN )); then
        printf '   (dry-run) %s\n' "$*"
    else
        "$@"
    fi
}

# ---------- 参数解析 ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump)
            [[ $# -ge 2 ]] || die "--bump 需要一个参数：patch|minor|major"
            case "$2" in patch|minor|major) BUMP_KIND="$2" ;; *) die "--bump 仅支持 patch|minor|major" ;; esac
            shift 2 ;;
        -m)
            [[ $# -ge 2 ]] || die "-m 需要一个提交信息参数"
            COMMIT_MSG="$2"
            shift 2 ;;
        --skip-install) INSTALL_APP=0; shift ;;
        --skip-wait) WAIT_CI=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$1（使用 -h 查看帮助）" ;;
    esac
done

# ---------- 前置检查 ----------
for tool in xcodebuild git curl python3 /usr/libexec/PlistBuddy; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少依赖工具：$tool"
done
command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || die "缺少依赖工具：/usr/libexec/PlistBuddy"
[ -f "$INFO_PLIST" ] || die "找不到 $INFO_PLIST，请在仓库根目录运行"
[ -f "$PBXPROJ" ] || die "找不到 $PBXPROJ"

# ---------- 版本处理 ----------
read_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST"
}

# semver 递增：1.5.1 patch -> 1.5.2；minor -> 1.6.0；major -> 2.0.0
bump_semver() {
    local old="$1" kind="$2" ma mi pa
    IFS=. read -r ma mi pa <<<"$old"
    case "$kind" in
        major) ma=$((ma + 1)); mi=0; pa=0 ;;
        minor) mi=$((mi + 1)); pa=0 ;;
        patch) pa=$((pa + 1)) ;;
    esac
    echo "$ma.$mi.$pa"
}

VERSION="$(read_version)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Info.plist 版本号格式非法：$VERSION（应为 x.y.z）"
fi
if [[ -n "$BUMP_KIND" ]]; then
    NEW_VERSION="$(bump_semver "$VERSION" "$BUMP_KIND")"
    log "版本递增：$VERSION -> $NEW_VERSION（$BUMP_KIND）"
    VERSION="$NEW_VERSION"
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
    die "tag v$VERSION 已存在，请改用 --bump 递增版本或删除旧 tag"
fi

log "目标版本：v$VERSION"
log "GitHub 仓库：$GH_REPO"
if (( DRY_RUN )); then log "dry-run 模式：仅检查，不执行" ; fi

# ---------- 版本号写入（仅 bump 时） ----------
if [[ -n "$BUMP_KIND" ]]; then
    if (( ! DRY_RUN )); then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
        sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
    else
        printf '   (dry-run) 写入版本：Info.plist + pbxproj MARKETING_VERSION = %s\n' "$VERSION"
    fi
    log "版本号已写入 Info.plist 与 pbxproj"
fi

# ---------- 提交检查 ----------
pending="$(git status --porcelain)"
if [[ -n "$pending" ]]; then
    if [[ -n "$COMMIT_MSG" ]]; then
        log "自动提交未提交改动：$COMMIT_MSG"
        run git add -A
        run git commit -m "$COMMIT_MSG"
    elif [[ -n "$BUMP_KIND" ]]; then
        # 仅版本号文件被改动时自动提交（其他文件改动需显式 -m）
        non_version="$(printf '%s\n' "$pending" | awk '{print $2}' | grep -vE "^(WallFlux/Info\.plist|WallFlux\.xcodeproj/project\.pbxproj)$" || true)"
        if [[ -z "$non_version" ]]; then
            log "自动提交版本号改动"
            run git add -A
            run git commit -m "版本号 v$VERSION"
        else
            die "工作区有非版本号改动，请先自行提交，或使用 -m '<提交信息>' 自动提交"
        fi
    else
        die "工作区有未提交改动，请先自行提交，或使用 -m '<提交信息>' 自动提交"
    fi
fi

# ---------- Release 构建 ----------
log "开始 Release 构建（xcodebuild $SCHEME Release）..."
if (( ! DRY_RUN )); then
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$BUILD_DIR" build \
        || die "Release 构建失败，请查看上方错误输出"
fi
[ -d "$APP_SRC" ] || die "构建产物缺失：$APP_SRC"
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_SRC/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    die "构建产物版本 $BUILT_VERSION 与目标版本 $VERSION 不一致，中止发布"
fi
log "构建成功：$APP_SRC（版本 $BUILT_VERSION）"

# ---------- 安装到 /Applications ----------
if (( INSTALL_APP )); then
    log "安装到 $APP_DST（先退出正在运行的 WallFlux）"
    run pkill -f WallFlux || true
    run rm -rf "$APP_DST"
    run ditto "$APP_SRC" "$APP_DST"
    INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DST/Contents/Info.plist")"
    [[ "$INSTALLED_VERSION" == "$VERSION" ]] || die "安装失败：$APP_DST 版本 $INSTALLED_VERSION 与目标不符"
    log "已安装：$APP_DST（版本 $INSTALLED_VERSION）"
else
    log "跳过安装（--skip-install）"
fi

# ---------- 打 tag 并推送 ----------
log "推送代码与 tag v$VERSION ..."
run git push origin main
run git tag "v$VERSION"
run git push origin "v$VERSION"

# ---------- 等待 CI 并校验 Release 资产 ----------
if (( ! WAIT_CI )); then
    log "已推送（--skip-wait），请自行到 https://github.com/$GH_REPO/actions 查看 Release workflow"
    exit 0
fi

wait_for_release() {
    local tag_name="$1" max_attempts=30
    for ((a = 1; a <= max_attempts; a++)); do
        local state status conclusion
        state="$(curl -sf "https://api.github.com/repos/$GH_REPO/actions/runs?per_page=100" 2>/dev/null \
            | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('workflow_runs', []):
    if r.get('name') == 'Release' and r.get('head_branch') == '$tag_name':
        print(r['status'], r.get('conclusion') or '')
        break
" || true)"
        if [[ -n "$state" ]]; then
            read -r status conclusion <<<"$state"
            case "$status/$conclusion" in
                completed/success)
                    log "Release workflow 完成（成功）"
                    return 0 ;;
                completed/*)
                    die "Release workflow 失败（conclusion=$conclusion），查看 https://github.com/$GH_REPO/actions" ;;
            esac
        fi
        printf '   [%02d/%02d] 等待 CI...\n' "$a" "$max_attempts"
        sleep 20
    done
    die "等待超时（$((max_attempts * 20)) 秒），请自行查看 https://github.com/$GH_REPO/actions"
}

if (( ! DRY_RUN )); then
    wait_for_release "v$VERSION"
    assets="$(curl -sf "https://api.github.com/repos/$GH_REPO/releases/tags/v$VERSION" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(a['name'] for a in d.get('assets', [])))
")"
    if [[ " $assets " == *" WallFlux-$VERSION.dmg "* ]]; then
        log "GitHub Release 已发布，DMG 资产就绪：WallFlux-$VERSION.dmg"
    else
        die "Release 缺少 DMG 资产（现有：$assets）"
    fi
fi

# ---------- 完成 ----------
echo
log "========== 发布完成：v$VERSION =========="
log "  - 本地已安装：$APP_DST"
log "  - GitHub Release：https://github.com/$GH_REPO/releases/tag/v$VERSION"
log "  - Homebrew cask 由 tap 仓库 sync-cask.yml 每 30 分钟自动同步，无需手动处理"
