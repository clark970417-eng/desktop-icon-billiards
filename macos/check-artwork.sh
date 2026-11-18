#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/artwork-checks"
mkdir -p "$CHECK_DIR"
swiftc -O "$MACOS_DIR/Sources/DesktopIconBilliards/ArtworkLoader.swift" \
    "$MACOS_DIR/ArtworkChecks/main.swift" -o "$CHECK_DIR/artwork-checks"
"$CHECK_DIR/artwork-checks"
