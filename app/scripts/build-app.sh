#!/bin/bash
# Build a double-clickable snapsift.app from the SwiftUI target — no Xcode needed.
#
#   ./scripts/build-app.sh                       # release → ~/Applications/snapsift.app
#   ./scripts/build-app.sh debug                 # faster debug build
#   ./scripts/build-app.sh release /tmp/snapsift.app   # custom destination
#
# Note: if this repo lives under an iCloud-synced folder, iCloud can touch a
# source file mid-build ("input file was modified during the build"). Just rerun,
# or build from a copy outside iCloud.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
DEST="${2:-$HOME/Applications/snapsift.app}"

echo "▸ swift build -c $CONFIG --product SnapsiftApp"
swift build -c "$CONFIG" --product SnapsiftApp
BIN=".build/$CONFIG/SnapsiftApp"

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BIN" "$DEST/Contents/MacOS/SnapsiftApp"
cp Info.plist "$DEST/Contents/Info.plist"
# App icon (regenerate with `swift run SnapsiftIcon` when the artwork changes).
cp Assets/AppIcon.icns "$DEST/Contents/Resources/AppIcon.icns"

# Localized TCC permission prompts. macOS reads InfoPlist.strings from the
# matching .lproj at request time, so a zh-TW / ja user sees the Photos-access
# justification in their own language instead of the English base string.
en_lproj="$DEST/Contents/Resources/en.lproj"
ja_lproj="$DEST/Contents/Resources/ja.lproj"
zh_lproj="$DEST/Contents/Resources/zh-TW.lproj"
mkdir -p "$en_lproj" "$ja_lproj" "$zh_lproj"

cat > "$en_lproj/InfoPlist.strings" <<'EOF'
"NSPhotoLibraryUsageDescription" = "snapsift reads your photo library on your Mac to find exact duplicates, burst shots, and look-alike photos so you can decide what to remove. Nothing leaves your device.";
"NSPhotoLibraryAddUsageDescription" = "snapsift modifies your library only to (1) sort candidates into \"Snapsift\" review albums so you can decide in your own time — a non-destructive label that leaves photos in place — and (2) when you choose, move photos you have reviewed and marked to Recently Deleted, where they remain recoverable for 30 days.";
EOF

cat > "$ja_lproj/InfoPlist.strings" <<'EOF'
"NSPhotoLibraryUsageDescription" = "snapsift はこの Mac 上で写真ライブラリを読み取り、完全な重複・連写・そっくりな写真を見つけて、削除するものをあなたが選べるようにします。データが端末の外に出ることはありません。";
"NSPhotoLibraryAddUsageDescription" = "snapsift がライブラリを変更するのは次の場合のみです：(1) 候補を「Snapsift」レビュー用アルバムに仕分ける（写真はそのまま残る非破壊的なラベル付け）、(2) あなたが選んだときに、確認して指定した写真を「最近削除した項目」へ移動する（30日間は復元可能）。";
EOF

cat > "$zh_lproj/InfoPlist.strings" <<'EOF'
"NSPhotoLibraryUsageDescription" = "snapsift 會在你的 Mac 上讀取照片圖庫，找出完全相同、連拍與看起來很像的照片，讓你決定要移除哪些。所有資料都不會離開你的裝置。";
"NSPhotoLibraryAddUsageDescription" = "snapsift 只會在以下情況更動你的圖庫：(1) 把候選照片整理進「Snapsift」檢視相簿（非破壞性的標記，照片仍留在原處）；(2) 當你選擇時，把你已檢視並標記的照片移到「最近刪除」，30 天內都可以復原。";
EOF

chmod +x "$DEST/Contents/MacOS/SnapsiftApp"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✓ Built $DEST"
echo "  Double-click it in Finder (first time: right-click → Open if macOS warns it's unsigned)."
echo "  It will ask for Photos access on first scan."
