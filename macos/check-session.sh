#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$MACOS_DIR"
BIN_DIR="$(swift build --package-path "$MACOS_DIR" --show-bin-path)"
CHECK_DIR="$MACOS_DIR/.build/session-checks"
mkdir -p "$CHECK_DIR"
swiftc -I "$BIN_DIR/Modules" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/GameView.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/Icons.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/ArtworkLoader.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopSnapshot.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopBackdrop.swift" \
    "$MACOS_DIR/SessionChecks/main.swift" \
    "$BIN_DIR/BilliardsCore.build/BilliardsGame.swift.o" -o "$CHECK_DIR/session-checks"
"$CHECK_DIR/session-checks"
