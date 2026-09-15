#!/bin/bash
# 把 SwiftPM 可执行文件打包成可双击运行的 ThreadPocket.app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="ThreadPocket"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$BUILD_DIR/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行文件：$BIN" >&2
  exit 1
fi

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Scripts/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ROOT/Scripts/AppIcon.icns" ]]; then
  cp "$ROOT/Scripts/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# 本地开发用临时签名，避免 Gatekeeper 直接拒绝启动
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
