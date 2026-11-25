#!/usr/bin/env bash
# 编译并打包 NetMonitor.app（需要 macOS + Xcode 命令行工具）
# 用法：scripts/build-app.sh [版本号]      产物：build/NetMonitor.app、build/NetMonitor-<版本>.zip
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
BUILD="${GITHUB_RUN_NUMBER:-$(date +%Y%m%d%H%M)}"
OUT=build
APP="$OUT/NetMonitor.app"

# 同时编译 Apple Silicon 与 Intel
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NetMonitor" "$APP/Contents/MacOS/NetMonitor"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

# 本地临时签名（ad-hoc），未经公证
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

(cd "$OUT" && rm -f "NetMonitor-$VERSION.zip" && ditto -c -k --keepParent NetMonitor.app "NetMonitor-$VERSION.zip")
echo "已生成 $APP 与 $OUT/NetMonitor-$VERSION.zip"
