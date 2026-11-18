#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$MACOS_DIR"
BIN_DIR="$(swift build --package-path "$MACOS_DIR" --show-bin-path)"
CHECK_DIR="$MACOS_DIR/.build/session-checks"
mkdir -p "$CHECK_DIR"
SOURCES=()
for SOURCE in "$MACOS_DIR"/Sources/DesktopIconBilliards/*.swift; do
    if [ "$(basename "$SOURCE")" != main.swift ]; then SOURCES+=("$SOURCE"); fi
done
swiftc -I "$BIN_DIR/Modules" "${SOURCES[@]}" \
    "$MACOS_DIR/SessionChecks/main.swift" \
    "$BIN_DIR/BilliardsCore.build/BilliardsGame.swift.o" -o "$CHECK_DIR/session-checks"
"$CHECK_DIR/session-checks"
