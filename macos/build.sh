#!/bin/bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
DIST_DIR="$MACOS_DIR/dist"
APP_PATH="$DIST_DIR/Desktop Icon Billiards.app"
ARCH_LABEL="$(uname -m)"
UNIVERSAL=false

case "${1:-}" in
    "") ;;
    --universal) UNIVERSAL=true; ARCH_LABEL=universal ;;
    *) echo "Usage: $0 [--universal]" >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--universal]" >&2
    exit 2
fi

mkdir -p "$DIST_DIR"

if "$UNIVERSAL"; then
    for ARCH in arm64 x86_64; do
        swift build --package-path "$MACOS_DIR" \
            --scratch-path "$MACOS_DIR/.build-$ARCH" --arch "$ARCH" -c release
    done
    ARM_BIN_DIR="$(swift build --package-path "$MACOS_DIR" \
        --scratch-path "$MACOS_DIR/.build-arm64" --arch arm64 -c release --show-bin-path)"
    INTEL_BIN_DIR="$(swift build --package-path "$MACOS_DIR" \
        --scratch-path "$MACOS_DIR/.build-x86_64" --arch x86_64 -c release --show-bin-path)"
    lipo -create "$ARM_BIN_DIR/DesktopIconBilliards" "$INTEL_BIN_DIR/DesktopIconBilliards" \
        -output "$DIST_DIR/DesktopIconBilliards-universal"
    EXECUTABLE="$DIST_DIR/DesktopIconBilliards-universal"
else
    swift build --package-path "$MACOS_DIR" -c release
    BIN_DIR="$(swift build --package-path "$MACOS_DIR" -c release --show-bin-path)"
    EXECUTABLE="$BIN_DIR/DesktopIconBilliards"
fi

# Only replace the generated bundle inside this script's own dist directory.
if [ -d "$APP_PATH" ]; then rm -rf "$APP_PATH"; fi
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$EXECUTABLE" "$APP_PATH/Contents/MacOS/DesktopIconBilliards"
cp "$MACOS_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$REPO_DIR/LICENSE" "$APP_PATH/Contents/Resources/LICENSE"
cp "$MACOS_DIR/README.md" "$APP_PATH/Contents/Resources/README.md"
chmod +x "$APP_PATH/Contents/MacOS/DesktopIconBilliards"

# Reuse the upstream icon, retaining its provenance in the bundled license.
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$REPO_DIR/assets/desktop-icon-billiards.png" \
        --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
    RETINA_SIZE=$((SIZE * 2))
    sips -z "$RETINA_SIZE" "$RETINA_SIZE" "$REPO_DIR/assets/desktop-icon-billiards.png" \
        --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

# Ad-hoc signing supports local testing; this is not Developer ID notarization.
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
ZIP_PATH="$DIST_DIR/DesktopIconBilliards-0.1.0-macOS-$ARCH_LABEL.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
printf '\nApp: %s\nArchive: %s\n' "$APP_PATH" "$ZIP_PATH"
