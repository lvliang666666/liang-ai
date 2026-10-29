#!/usr/bin/env bash
# =============================================================================
# Liang AI 发版脚本（版本管理规范 E8/R1：规范工具化第一个实例）
#
# 把发版流程的机械步骤脚本化，人只留两个判断和一个门槛：
#   - 判断 1：版本号位（patch/minor/major）→ 命令参数
#   - 判断 2：VERSIONING.md 更新清单 → 人写（脚本前置校验已写）
#   - 门槛：真机验收 → 脚本尾部提醒，不能代替
#
# 用法：
#   ./release.sh patch|minor|major        正式发版（完整流程）
#   ./release.sh --preview <批次名>       验收包（不 bump/不 tag/不动版本号）
#   ./release.sh --continue               断点续跑（release 提交+tag 已存在时）
#
# 规范依据：版本管理规范/versioning.md 发版流程；合并点不归本脚本管
# （merge 属批次流程，先合并批次分支再跑本脚本）。
# =============================================================================
set -euo pipefail

# ===== 项目配置区（换项目改这里） =====
APP_NAME="LiangAI"                                    # 归档命名用
PUBSPEC="pubspec.yaml"                                # 版本声明文件
VERSIONING="VERSIONING.md"                            # 版本记录文件
# E11 ③：--split-per-abi 出 ABI 独立包（arm64 包体积约为通用包 1/3）。
# 归档取 arm64-v8a（现代 Android 设备全覆盖）；x86_64 包仅模拟器用，
# armeabi-v7a 包给老设备（如需可从 build 目录手动取）。
BUILD_CMD=("/d/flutter/bin/flutter" "build" "apk" "--release" "--split-per-abi")
ARTIFACT="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
# split-per-abi 下 versionCode = abiVersionCode * 1000 + buildNo
# （FlutterPlugin.kt：arm64=2, armeabi-v7a=1, x86_64=4），aapt 校验用
ABI_VERSION_CODE=2
AAPT="$LOCALAPPDATA/Android/Sdk/build-tools/36.0.0/aapt"
RELEASES_DIR="releases"
# 构建环境（Clash 代理；flutter test 需 NO_PROXY 防代理劫持本地端口）
export GRADLE_OPTS="-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7897 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7897"
export NO_PROXY="127.0.0.1,localhost"
# ===== 配置区结束 =====

c_info='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'; c_off='\033[0m'
info()  { echo -e "${c_info}▶ $*${c_off}"; }
ok()    { echo -e "${c_ok}✓ $*${c_off}"; }
warn()  { echo -e "${c_warn}⚠ $*${c_off}"; }
die()   { echo -e "${c_err}✗ $*${c_off}" >&2; exit 1; }

# ---------- 参数解析 ----------
MODE="release"; BUMP=""; PREVIEW_NAME=""
case "${1:-}" in
  patch|minor|major) MODE="release"; BUMP="$1" ;;
  --preview)  MODE="preview";  [ -n "${2:-}" ] || die "--preview 需要批次名：./release.sh --preview <批次名>"; PREVIEW_NAME="$2" ;;
  --continue) MODE="continue" ;;
  "") die "用法：./release.sh patch|minor|major ｜ --preview <批次名> ｜ --continue" ;;
  *) die "未知参数：$1" ;;
esac

# ---------- 前置检查 ----------
info "前置检查"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "不在 git 仓库内"
# main 分支要求只约束正式发版（tag 必须打在 main 上）；preview 包不 bump
# 不 tag，在批次分支上构建是正常场景（批次开发中途出验收包）
if [ "$MODE" != "preview" ]; then
  [ "$(git branch --show-current)" = "main" ] || die "正式发版必须在 main 分支（当前：$(git branch --show-current)）"
fi
[ -z "$(git status --porcelain)" ] || die "工作区不干净，先提交或暂存：\n$(git status --short)"

CUR_VERSION=$(grep -E '^version:' "$PUBSPEC" | sed -E 's/^version: *([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+).*/\1 \2/')
VERSION=$(echo "$CUR_VERSION" | cut -d' ' -f1)
BUILD_NO=$(echo "$CUR_VERSION" | cut -d' ' -f2)

if [ "$MODE" = "preview" ]; then
  # 验收包：不动版本号（版本号属发版提交），归档带 preview 后缀
  OUT_FILE="${RELEASES_DIR}/${APP_NAME}-v${VERSION}-${PREVIEW_NAME}-preview1.apk"
  ok "preview 模式：版本保持 v${VERSION}+${BUILD_NO}，产物 → ${OUT_FILE}"
  info "构建 APK"
  "${BUILD_CMD[@]}" || die "构建失败"
  [ -f "$ARTIFACT" ] || die "产物不存在：$ARTIFACT"
  info "aapt 校验"
  BADGING=$("$AAPT" dump badging "$ARTIFACT" 2>/dev/null) || die "aapt 不可用：$AAPT"
  echo "$BADGING" | grep -q "versionName='${VERSION}'" || die "versionName 不符（期望 ${VERSION}）：$(echo "$BADGING" | head -1)"
  # split-per-abi：arm64 包 versionCode = ABI_VERSION_CODE * 1000 + buildNo
  PREVIEW_CODE=$((ABI_VERSION_CODE * 1000 + BUILD_NO))
  echo "$BADGING" | grep -q "versionCode='${PREVIEW_CODE}'" || die "versionCode 不符（期望 ${PREVIEW_CODE}）：$(echo "$BADGING" | head -1)"
  mkdir -p "$RELEASES_DIR"
  cp "$ARTIFACT" "$OUT_FILE"
  ok "验收包已归档：${OUT_FILE}（版本号未动，验收通过后走正式发版）"
  exit 0
fi

# 正式/续跑模式：计算新版本号
IFS='.' read -r MA MI PA <<< "$VERSION"
case "$BUMP" in
  patch) NEW_VERSION="${MA}.${MI}.$((PA + 1))" ;;
  minor) NEW_VERSION="${MA}.$((MI + 1)).0" ;;
  major) NEW_VERSION="$((MA + 1)).0.0" ;;
  *)     NEW_VERSION="$VERSION" ;;  # continue 模式沿用当前版本
esac
NEW_BUILD=$((BUILD_NO + 1))
OUT_FILE="${RELEASES_DIR}/${APP_NAME}-v${NEW_VERSION}.apk"
TAG="v${NEW_VERSION}"

if [ "$MODE" = "continue" ]; then
  info "断点续跑：检测已完成步骤"
  git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || die "续跑要求 tag ${TAG} 已存在（否则用正式模式从头跑）"
  ok "tag ${TAG} 已存在（tag 指向提交、产物可复现，无需重建）"
else
  # 正式模式前置：清单先写（VERSIONING.md 已含新版本号）
  grep -q "v${NEW_VERSION}" "$VERSIONING" || die "VERSIONING.md 还没有 v${NEW_VERSION} 的条目——更新清单是发版必写项（第 6 步），先写再跑脚本"
  info "版本号决策：v${VERSION}+${BUILD_NO} → v${NEW_VERSION}+${NEW_BUILD}（${BUMP}）"
  # ① 验证全绿
  info "① analyze + test 全绿"
  # analyze 有 info 也返回非零码——pipefail 下会吞掉 grep 命中，先落文件再 grep；
  # 级别词在行首（「   error - 消息」），分隔符平台相关只锚定级别词+空白
  /d/flutter/bin/flutter analyze > /tmp/analyze_release.txt 2>&1 || true
  grep -q "issues found" /tmp/analyze_release.txt || die "analyze 未正常完成：$(cat /tmp/analyze_release.txt | tail -5)"
  grep -qE "^[[:space:]]*(error|warning)([[:space:]]|$)" /tmp/analyze_release.txt && die "analyze 有 error/warning，先修完再发版"
  ok "analyze 零 error/warning"
  /d/flutter/bin/flutter test || die "测试未全绿"
  # ② 版本号 bump
  info "② bump ${PUBSPEC}: ${VERSION}+${BUILD_NO} → ${NEW_VERSION}+${NEW_BUILD}"
  sed -i -E "s/^version: ${VERSION//./\\.}\\+${BUILD_NO}$/version: ${NEW_VERSION}+${NEW_BUILD}/" "$PUBSPEC"
  grep -q "^version: ${NEW_VERSION//./\\.}+${NEW_BUILD}$" "$PUBSPEC" || die "版本号替换失败，请手动检查 ${PUBSPEC}"
  ok "版本号已更新"
  # ③ release 提交（只 add 版本文件——结构上不可能夹带）
  info "③ release 提交"
  git add "$PUBSPEC"
  [ -z "$(git status --porcelain -- "$PUBSPEC")" ] && die "版本号无变化？确认 ${PUBSPEC} 当前值"
  git commit -m "release: 发布 v${NEW_VERSION}"
  ok "release 提交完成"
  # ④ tag
  info "④ 打 tag ${TAG}"
  git tag -a "$TAG" -m "发布 v${NEW_VERSION}"
  ok "tag 完成"
fi

# ⑤ 构建（续跑时重跑构建无害：产物可复现）
info "⑤ 构建 APK"
"${BUILD_CMD[@]}" || die "构建失败（修复后可用 ./release.sh --continue 续跑，tag 无需删）"
[ -f "$ARTIFACT" ] || die "产物不存在：$ARTIFACT"

# ⑥ 产物校验（不过则中止，不归档）
info "⑥ aapt 校验产物与 tag 对应"
BADGING=$("$AAPT" dump badging "$ARTIFACT" 2>/dev/null) || die "aapt 不可用：$AAPT"
echo "$BADGING" | grep -q "versionName='${NEW_VERSION}'" || die "versionName 不符（期望 ${NEW_VERSION}）：$(echo "$BADGING" | head -1)"
# split-per-abi：arm64 包 versionCode = ABI_VERSION_CODE * 1000 + buildNo
EXPECTED_CODE=$((ABI_VERSION_CODE * 1000 + NEW_BUILD))
echo "$BADGING" | grep -q "versionCode='${EXPECTED_CODE}'" || die "versionCode 不符（期望 ${EXPECTED_CODE} = ABI ${ABI_VERSION_CODE}×1000 + ${NEW_BUILD}）：$(echo "$BADGING" | head -1)"
ok "versionName=${NEW_VERSION} versionCode=${EXPECTED_CODE}（arm64）校验通过"

# ⑦ 归档
info "⑦ 归档 ${OUT_FILE}"
mkdir -p "$RELEASES_DIR"
cp "$ARTIFACT" "$OUT_FILE"
ok "归档完成"

echo
echo -e "${c_ok}==============================================${c_off}"
echo -e "${c_ok}  v${NEW_VERSION} 发版完成（arm64 versionCode ${EXPECTED_CODE}）${c_off}"
echo -e "${c_ok}==============================================${c_off}"
warn "别忘了：① 真机验收（脚本不能代替）② VERSIONING.md 更新清单如未写全，补完单独提交"
warn "其他 ABI 产物（如需）：build/app/outputs/flutter-apk/app-{armeabi-v7a,x86_64}-release.apk"
