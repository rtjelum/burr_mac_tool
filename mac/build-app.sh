#!/bin/bash
# Builds the native SwiftUI version of BurrTools as build/BurrTools.app.
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
BUNDLE="build/BurrTools.app"

swift build -c release --product BurrTools
BIN="$(swift build -c release --show-bin-path)/BurrTools"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/BurrTools"
sed "s/@VERSION@/$VERSION/g" mac/Info.plist > "$BUNDLE/Contents/Info.plist"

# App icon from the original Windows icon (largest size it contains)
ICONSET="$(mktemp -d)/BurrTools.iconset"
mkdir -p "$ICONSET"
if sips -s format png burricons.ico --out "$ICONSET/base.png" >/dev/null 2>&1; then
    for s in 16 32 64 128 256 512; do
        sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    done
    rm "$ICONSET/base.png"
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/BurrTools.icns" || true
fi

# Ad-hoc signature so macOS will run it locally
codesign --force --sign - "$BUNDLE"

echo "Built $BUNDLE"
