#!/bin/bash
# Build a double-clickable snapsift.app from the SwiftUI target — no Xcode needed.
#
#   ./scripts/build-app.sh                       # release → ~/Desktop/snapsift.app
#   ./scripts/build-app.sh debug                 # faster debug build
#   ./scripts/build-app.sh release /tmp/snapsift.app   # custom destination
#
# Note: if this repo lives under an iCloud-synced folder, iCloud can touch a
# source file mid-build ("input file was modified during the build"). Just rerun,
# or build from a copy outside iCloud.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
DEST="${2:-$HOME/Desktop/snapsift.app}"

echo "▸ swift build -c $CONFIG --product SnapsiftApp"
swift build -c "$CONFIG" --product SnapsiftApp
BIN=".build/$CONFIG/SnapsiftApp"

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
cp "$BIN" "$DEST/Contents/MacOS/SnapsiftApp"
cp Info.plist "$DEST/Contents/Info.plist"

chmod +x "$DEST/Contents/MacOS/SnapsiftApp"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ Built $DEST"
echo "  Double-click it in Finder (first time: right-click → Open if macOS warns it's unsigned)."
echo "  It will ask for Photos access on first scan."
