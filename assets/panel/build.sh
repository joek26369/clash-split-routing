#!/bin/bash
# build.sh — 从源码构建代理出口面板（.app）
#
#   ./build.sh                 构建到 ~/Applications/ExitPanel.app
#   ./build.sh --install       构建并注册开机自启（launchd）
#   ./build.sh --run           构建后立即启动
#
# 依赖：Xcode Command Line Tools（提供 swiftc）

set -eu
export LC_ALL=en_US.UTF-8

cd "$(dirname "$0")"

APP_NAME="ExitPanel"
DEST="${HOME}/Applications/${APP_NAME}.app"
BUNDLE_ID="local.exitpanel"

INSTALL=0
RUN=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --run)     RUN=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: ${a}" >&2; exit 2 ;;
  esac
done

command -v swiftc >/dev/null 2>&1 || {
  echo "FAIL: 找不到 swiftc。先装 Xcode Command Line Tools：" >&2
  echo "      xcode-select --install" >&2
  exit 1
}

echo "════════ 构建 ${APP_NAME} ════════"

# ⚠️ @main 必须配 -parse-as-library，否则 swiftc 报
#    "'main' attribute cannot be used in a module that contains top-level code"
swiftc -O -parse-as-library main.swift -o "${APP_NAME}.new"
echo "  ✅ 编译完成"

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "${APP_NAME}.new" "$DEST/Contents/MacOS/${APP_NAME}"
chmod +x "$DEST/Contents/MacOS/${APP_NAME}"

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>代理出口面板</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 本地自用必须 ad-hoc 签名，否则每次启动都会被 Gatekeeper 拦
codesign --force --sign - "$DEST" 2>/dev/null && echo "  ✅ 已 ad-hoc 签名"

# 清掉 quarantine，避免「无法验证开发者」
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "  ✅ 已生成 $DEST"

if [ "$INSTALL" = 1 ]; then
  PLIST_SRC="$(pwd)/${BUNDLE_ID}.plist"
  PLIST_DST="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
  mkdir -p "${HOME}/Library/LaunchAgents"
  sed "s|__APP_PATH__|${DEST}|g" "$PLIST_SRC" > "$PLIST_DST"
  launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
  echo "  ✅ 已注册开机自启（${PLIST_DST}）"
fi

if [ "$RUN" = 1 ]; then
  open "$DEST"
  echo "  ✅ 已启动"
fi

echo ""
echo "提示：面板依赖 ~/proxy-tools/switch-exit.sh"
echo "      把 scripts/switch-exit.sh 与 config.env 复制过去即可。"
