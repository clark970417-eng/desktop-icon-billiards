#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/information-checks"
mkdir -p "$CHECK_DIR"
swiftc "$MACOS_DIR/Sources/DesktopIconBilliards/Localization.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/PlatformSupport.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/Information.swift" \
    "$MACOS_DIR/InformationChecks/main.swift" -o "$CHECK_DIR/information-checks"
# Development artwork resolution uses the repository's original asset.
cd "$MACOS_DIR/.."
"$CHECK_DIR/information-checks"
