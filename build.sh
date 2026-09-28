#!/bin/bash
set -euo pipefail

ARCH="${1:?用法: ./build.sh arm64|x86_64}"
case "$ARCH" in arm64|x86_64) ;; *) echo "不支持的架构：$ARCH" >&2; exit 2;; esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="$ROOT/build/$ARCH"
BUNDLE="$BUILD_ROOT/products/LiveNanjing.saver"
EXECUTABLE="$BUNDLE/Contents/MacOS/LiveNanjing"

rm -rf "$BUILD_ROOT"
xcodebuild \
    -project "$ROOT/LiveNanjing.xcodeproj" \
    -target LiveNanjing \
    -configuration Release \
    ARCHS="$ARCH" \
    ONLY_ACTIVE_ARCH=YES \
    CONFIGURATION_BUILD_DIR="$BUILD_ROOT/products" \
    CODE_SIGNING_ALLOWED=NO \
    build

codesign --force --deep --sign - "$BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
test "$(lipo -archs "$EXECUTABLE")" = "$ARCH"
test -f "$BUNDLE/Contents/Resources/thumbnail.tiff"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$BUILD_ROOT/LiveNanjing-$ARCH.saver.zip"
echo "$BUILD_ROOT/LiveNanjing-$ARCH.saver.zip"
