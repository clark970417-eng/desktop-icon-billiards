#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/presentation-checks"
mkdir -p "$CHECK_DIR"
swiftc -O "$MACOS_DIR/Sources/DesktopIconBilliards/Localization.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/Results.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/CueAppearance.swift" \
    "$MACOS_DIR/PresentationChecks/main.swift" -o "$CHECK_DIR/presentation-checks"
"$CHECK_DIR/presentation-checks"
