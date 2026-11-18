#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$MACOS_DIR/.build/ranking-checks"
mkdir -p "$CHECK_DIR"
# The fixture declares its own language enum and intercepts every URL request.
# No network request can leave the URLProtocol mock, including accidental hosts.
swiftc "$MACOS_DIR/Sources/DesktopIconBilliards/Ranking.swift" \
    "$MACOS_DIR/RankingChecks/main.swift" -o "$CHECK_DIR/ranking-checks"
"$CHECK_DIR/ranking-checks"
