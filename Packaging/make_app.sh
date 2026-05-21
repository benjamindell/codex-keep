#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$BUILD_DIR/Codex Keep.app"

cd "$ROOT_DIR"
swift build -c release --product CodexKeep

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"
cp "$BUILD_DIR/CodexKeep" "$APP_DIR/Contents/MacOS/CodexKeep"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

if [ -d "$BUILD_DIR/Sparkle.framework" ]; then
  cp -R "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$APP_DIR/Contents/MacOS/CodexKeep" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_DIR/Contents/MacOS/CodexKeep"
  fi
fi

codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
