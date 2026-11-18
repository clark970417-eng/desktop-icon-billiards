#!/bin/bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/desktop-checks"
mkdir -p "$CHECK_DIR"

# Uses generated NSAppleEventDescriptor fixtures and injected empty artwork.
# It never calls DesktopSnapshot.read() or DesktopBackdrop.read(screen:).
swiftc -O "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopBackdrop.swift" \
    "$MACOS_DIR/Sources/DesktopIconBilliards/DesktopSnapshot.swift" \
    "$MACOS_DIR/DesktopChecks/main.swift" -o "$CHECK_DIR/desktop-checks"
"$CHECK_DIR/desktop-checks"
