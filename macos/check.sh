#!/bin/bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/standalone-checks"
mkdir -p "$CHECK_DIR"

# Compile in one module so the checks work with Command Line Tools alone.
# XCTest remains available separately for developers with full Xcode.
swiftc -O "$MACOS_DIR/Sources/BilliardsCore/BilliardsGame.swift" \
    "$MACOS_DIR/Checks/main.swift" -o "$CHECK_DIR/physics-checks"
"$CHECK_DIR/physics-checks"
