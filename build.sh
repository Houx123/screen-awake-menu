#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/熄屏不休眠.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$MODULE_CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" xcrun swiftc \
  -O \
  -framework Cocoa \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/ScreenAwakeMenu"

cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "$APP_DIR"
