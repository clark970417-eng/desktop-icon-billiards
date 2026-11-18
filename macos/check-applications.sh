#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/applications-checks"
mkdir -p "$CHECK_DIR"
swiftc -O "$MACOS_DIR/Sources/DesktopIconBilliards/Icons.swift" \
    "$MACOS_DIR/ApplicationsChecks/main.swift" -o "$CHECK_DIR/applications-checks"
"$CHECK_DIR/applications-checks"
