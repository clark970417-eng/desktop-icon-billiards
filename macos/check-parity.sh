#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/parity-checks"
mkdir -p "$CHECK_DIR"
swiftc -O \
    "$MACOS_DIR/Sources/DesktopIconBilliards/PlatformSupport.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/WindowsStyle.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopSelection.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/Localization.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopSnapshot.swift" \
    "$MACOS_DIR/ParityChecks/main.swift" -o "$CHECK_DIR/parity-checks"
"$CHECK_DIR/parity-checks"
