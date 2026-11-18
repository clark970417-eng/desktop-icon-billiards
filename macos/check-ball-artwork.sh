#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/ball-artwork-checks"
mkdir -p "$CHECK_DIR"
swiftc -O "$MACOS_DIR/Sources/DesktopIconBilliards/BallArtwork.swift" \
    "$MACOS_DIR/BallArtworkChecks/main.swift" -o "$CHECK_DIR/ball-artwork-checks"
"$CHECK_DIR/ball-artwork-checks"
