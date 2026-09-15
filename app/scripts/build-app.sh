#!/bin/bash
# Build a double-clickable snapsift.app from the SwiftUI target — no Xcode needed.
#
#   ./scripts/build-app.sh                       # release → ~/Applications/snapsift.app
#   ./scripts/build-app.sh debug                 # faster debug build
#   ./scripts/build-app.sh release /tmp/snapsift.app   # custom destination
#
# This produces the UNSIGNED dev-loop build only (right-click → Open warning
# and all). The signed, notarized, auto-updating "official binary" is this
# same output run through cver-tools' mac-release/release.sh — see
# docs/UPDATES.md for the full release sequence and where the Sparkle
# EdDSA key / feed URL come from.
#
# Env vars (both optional — omitting either still produces a working, just
# non-auto-updating, app; see the loud warning below when the key is unset):
#   SNAPSIFT_FEED_URL           SUFeedURL. Default: the production appcast.
#   SNAPSIFT_SU_PUBLIC_ED_KEY   SUPublicEDKey (the EdDSA PUBLIC half only —
#                                generated once via generate_keys, see
#                                scripts/make-appcast.sh; never the private key).
#
# Note: if this repo lives under an iCloud-synced folder, iCloud can touch a
# source file mid-build ("input file was modified during the build"). Just rerun,
# or build from a copy outside iCloud.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_ROOT="$(pwd)"

CONFIG="${1:-release}"
DEST="${2:-$HOME/Applications/snapsift.app}"
FEED_URL="${SNAPSIFT_FEED_URL:-https://oss.cver.net/snapsift/appcast.xml}"
PUBLIC_ED_KEY="${SNAPSIFT_SU_PUBLIC_ED_KEY:-}"

echo "▸ swift build -c $CONFIG --product SnapsiftApp"
swift build -c "$CONFIG" --product SnapsiftApp
BIN=".build/$CONFIG/SnapsiftApp"
SPARKLE_FRAMEWORK=".build/$CONFIG/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "✗ $SPARKLE_FRAMEWORK not found next to the built executable." >&2
  echo "  Expected SwiftPM to stage it there as SnapsiftApp's Sparkle dependency" >&2
  echo "  (see app/Package.swift). Check the build log above for a Sparkle" >&2
  echo "  resolution/build failure." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources" "$DEST/Contents/Frameworks"
cp "$BIN" "$DEST/Contents/MacOS/SnapsiftApp"
cp Info.plist "$DEST/Contents/Info.plist"
# App icon (regenerate with `swift run SnapsiftIcon` when the artwork changes).
cp Assets/AppIcon.icns "$DEST/Contents/Resources/AppIcon.icns"

# Sparkle.framework: embed the whole versioned bundle (its internal symlinks —
# Versions/Current, the top-level Sparkle/Resources/etc. aliases — must
# survive the copy, hence ditto rather than a plain recursive cp). Autoupdate
# and the XPC services Sparkle needs for a SANDBOXED host already live inside
# it; snapsift is not sandboxed (see Resources/snapsift.entitlements) so it
# never touches the XPC path, but they ship along regardless — that's how
# Sparkle's own binaryTarget is laid out.
echo "▸ embedding Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$DEST/Contents/Frameworks/Sparkle.framework"

# The executable's own rpath list (baked in by SwiftPM) is `@loader_path`,
# `/usr/lib/swift`, and the toolchain's swift-6.2 lib dir — none of which
# resolve to Contents/Frameworks, the standard place a signed .app looks for
# its embedded frameworks. Sparkle's dylib is linked against
# `@rpath/Sparkle.framework/Versions/B/Sparkle` (see the otool -L line
# printed below), so add the one rpath that makes `@rpath` resolve there:
# the conventional `@executable_path/../Frameworks`. Idempotent to rerun
# (each run starts from a fresh copy of $BIN, never the .build original).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$DEST/Contents/MacOS/SnapsiftApp"

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

# Sparkle keys, added to the copied Info.plist (never to the committed
# source app/Info.plist — these three are build-time / environment-driven,
# not static app identity). NSPhotoLibraryUsageDescription is already in the
# source plist; verified below rather than re-added here.
PLIST="$DEST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$PLIST"
# Zero telemetry beyond Sparkle's own version/OS check (see docs/UPDATES.md):
# explicitly OFF, not just "left at its default", so it reads the same way
# in every build regardless of what Sparkle's own default happens to be.
/usr/libexec/PlistBuddy -c "Add :SUEnableSystemProfiling bool false" "$PLIST"
if [ -n "$PUBLIC_ED_KEY" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_ED_KEY" "$PLIST"
else
  echo "⚠️  SNAPSIFT_SU_PUBLIC_ED_KEY is not set — SUPublicEDKey omitted." >&2
  echo "⚠️  This build CANNOT auto-update: Sparkle refuses to trust an appcast" >&2
  echo "⚠️  with no public key to verify it against. Fine for local dev; the" >&2
  echo "⚠️  official signed binary must set this (see docs/UPDATES.md)." >&2
fi

if ! /usr/libexec/PlistBuddy -c "Print :NSPhotoLibraryUsageDescription" "$PLIST" >/dev/null 2>&1; then
  echo "✗ NSPhotoLibraryUsageDescription missing from $PLIST — TCC would hang." >&2
  exit 1
fi

chmod +x "$DEST/Contents/MacOS/SnapsiftApp"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "▸ verifying the embedded framework"
plutil -lint "$PLIST"
echo "  Sparkle link (expect @rpath, resolved via the added rpath above):"
otool -L "$DEST/Contents/MacOS/SnapsiftApp" | grep -i sparkle | sed 's/^/  /'
echo "  Framework present: $DEST/Contents/Frameworks/Sparkle.framework"
echo "  Entitlements for the signing pipeline (mac-release/release.sh --entitlements):"
echo "  $APP_ROOT/Resources/snapsift.entitlements"

echo "✓ Built $DEST"
echo "  Double-click it in Finder (first time: right-click → Open if macOS warns it's unsigned)."
echo "  It will ask for Photos access on first scan."
