#!/usr/bin/env bash
# 安装 NetMonitor：解压下载的安装包、复制到“应用程序”、解除系统隔离标记并启动。
#
# 用法：
#   bash install.sh                          # 自动使用“下载”文件夹里最新的 NetMonitor*.zip
#   bash install.sh ~/Downloads/NetMonitor.zip
#   bash install.sh ~/Downloads/NetMonitor.app
#
# 安装包没有经过 Apple 公证，系统会给下载的文件加上隔离标记并拦截打开；
# 本脚本用 xattr 去掉这个标记，等同于在“隐私与安全性”里点“仍要打开”。
set -euo pipefail

DEST="/Applications/NetMonitor.app"
SRC="${1:-}"

if [[ -z "$SRC" ]]; then
  SRC=$(ls -t "$HOME"/Downloads/NetMonitor*.zip 2>/dev/null | head -n 1 || true)
  if [[ -z "$SRC" ]]; then
    echo "在“下载”文件夹里没找到 NetMonitor*.zip，请把安装包路径作为参数传入。" >&2
    exit 1
  fi
fi
[[ -e "$SRC" ]] || { echo "找不到 $SRC" >&2; exit 1; }
echo "安装包：$SRC"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ "$SRC" == *.app || -d "$SRC" ]]; then
  APP="$SRC"
else
  ditto -x -k "$SRC" "$WORK/unzipped"
  # GitHub Actions 的构建产物是“zip 里再套一个 zip”，逐层解开
  while APP=$(find "$WORK/unzipped" -maxdepth 3 -name "NetMonitor.app" -type d | head -n 1); [[ -z "$APP" ]]; do
    INNER=$(find "$WORK/unzipped" -name "*.zip" | head -n 1)
    [[ -n "$INNER" ]] || { echo "安装包里没有 NetMonitor.app" >&2; exit 1; }
    ditto -x -k "$INNER" "$WORK/unzipped/$(basename "$INNER" .zip)"
    rm -f "$INNER"
  done
fi

# 已在运行的旧版本先退出
if pgrep -x NetMonitor >/dev/null; then
  echo "退出正在运行的 NetMonitor…"
  osascript -e 'quit app "NetMonitor"' >/dev/null 2>&1 || pkill -x NetMonitor || true
  sleep 1
fi

echo "复制到 $DEST"
if [[ -w /Applications ]]; then
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
else
  sudo rm -rf "$DEST"
  sudo ditto "$APP" "$DEST"
  sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
fi

echo "启动 NetMonitor（图标在菜单栏右上角）"
open "$DEST"
