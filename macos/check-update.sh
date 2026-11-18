#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/update-checks"
mkdir -p "$CHECK_DIR"
# All URL requests are intercepted; this does not check real GitHub releases.
swiftc "$MACOS_DIR/Sources/DesktopIconBilliards/MacUpdateController.swift" \
    "$MACOS_DIR/UpdateChecks/main.swift" -o "$CHECK_DIR/update-checks"
"$CHECK_DIR/update-checks"
