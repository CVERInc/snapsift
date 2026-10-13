#!/usr/bin/env bash
# scripts/release.sh — the official-binary release chain, one command:
#
#   build-app.sh  →  cver-tools mac-release/release.sh  →  make-appcast.sh
#   (build+embed     (sign inside-out, notarize,          (EdDSA-signed
#    Sparkle)         staple, dmg)                         appcast.xml)
#
#   scripts/release.sh           # preflight, build, sign+notarize, appcast
#   scripts/release.sh check     # build + mac-release --preflight; nothing is signed
#   scripts/release.sh publish   # copy the result into the hosting checkout
#                                #   (does NOT commit or push; prints how)
#
# Required environment (fails with a clear message when missing):
#   SNAPSIFT_MAC_RELEASE        path to cver-tools' mac-release/release.sh
#                               (the private signing pipeline; not in this repo)
#   SNAPSIFT_SU_PUBLIC_ED_KEY   Sparkle EdDSA PUBLIC key (from generate_keys,
#                               run once by a human — see docs/UPDATES.md)
#   SNAPSIFT_IDENTITY           "Developer ID Application: … (TEAMID)"
# Optional:
#   SNAPSIFT_NOTARY_PROFILE     notarytool keychain profile (default cver-notary)
#   SNAPSIFT_BASE_URL           THE one hosting variable. The directory URL
#                               that serves appcast.xml AND the release
#                               archives. Default https://oss.cver.net/snapsift/
#                               It feeds SUFeedURL (build-app.sh) and the
#                               appcast download prefix (make-appcast.sh).
#                               Finer overrides still win: SNAPSIFT_FEED_URL,
#                               SNAPSIFT_DOWNLOAD_URL_PREFIX.
#   SNAPSIFT_RELEASES_DIR       where archives + appcast.xml accumulate
#                               (default dist/releases; keep ALL past releases
#                               here — generate_appcast rewrites the feed from it)
#   SNAPSIFT_PUBLISH_DIR        (publish) local checkout of whatever serves
#                               SNAPSIFT_BASE_URL
#
# Hosting requirement: SNAPSIFT_BASE_URL must return 200 for appcast.xml and
# for each archive it names, over HTTPS, before the first official build ships
# (see docs/UPDATES.md "Hosting"). This script never touches DNS, Pages
# settings or any remote; `publish` only copies files.
#
# Never launches the app. Never runs generate_keys.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

CMD="${1:-all}"
case "$CMD" in all|check|publish) ;; -h|--help) sed -n '2,45p' "$0"; exit 0 ;; *) echo "usage: $0 [check|publish]" >&2; exit 2 ;; esac

die() { echo "✗ $*" >&2; exit 1; }

BASE_URL="${SNAPSIFT_BASE_URL:-https://oss.cver.net/snapsift/}"
case "$BASE_URL" in */) ;; *) BASE_URL="$BASE_URL/" ;; esac
export SNAPSIFT_FEED_URL="${SNAPSIFT_FEED_URL:-${BASE_URL}appcast.xml}"
export SNAPSIFT_DOWNLOAD_URL_PREFIX="${SNAPSIFT_DOWNLOAD_URL_PREFIX:-$BASE_URL}"
RELEASES_DIR="${SNAPSIFT_RELEASES_DIR:-$REPO_ROOT/dist/releases}"
STAGE_DIR="$REPO_ROOT/dist/stage"
NOTARY_PROFILE="${SNAPSIFT_NOTARY_PROFILE:-cver-notary}"
PLIST="$REPO_ROOT/app/Info.plist"
ENTITLEMENTS="$REPO_ROOT/app/Resources/snapsift.entitlements"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
APP="$STAGE_DIR/snapsift.app"
DMG="$RELEASES_DIR/snapsift-$VERSION.dmg"

if [ "$CMD" = publish ]; then
  [ -n "${SNAPSIFT_PUBLISH_DIR:-}" ] || die "SNAPSIFT_PUBLISH_DIR is not set (a local checkout of the host serving $BASE_URL)"
  [ -d "$SNAPSIFT_PUBLISH_DIR" ] || die "SNAPSIFT_PUBLISH_DIR is not a directory: $SNAPSIFT_PUBLISH_DIR"
  [ -f "$RELEASES_DIR/appcast.xml" ] || die "no $RELEASES_DIR/appcast.xml — run scripts/release.sh first"
  [ -f "$DMG" ] || die "no $DMG — run scripts/release.sh first"
  cp "$RELEASES_DIR/appcast.xml" "$SNAPSIFT_PUBLISH_DIR/appcast.xml"
  cp "$DMG" "$DMG.sha256" "$SNAPSIFT_PUBLISH_DIR/"
  echo "✓ copied appcast.xml, $(basename "$DMG") and its .sha256 into $SNAPSIFT_PUBLISH_DIR"
  echo "  Nothing was committed or pushed. To go live, commit those files in that"
  echo "  checkout and push it, then verify (all must print 200):"
  echo "    curl -sI ${BASE_URL}appcast.xml | head -1"
  echo "    curl -sIL ${BASE_URL}$(basename "$DMG") | grep -i '^HTTP'"
  exit 0
fi

# ── requirements (fail early, before the slow part) ──────────────────────
[ -n "${SNAPSIFT_MAC_RELEASE:-}" ] || die "SNAPSIFT_MAC_RELEASE is not set. Point it at cver-tools' mac-release/release.sh (the private signing pipeline), e.g. export SNAPSIFT_MAC_RELEASE=~/Developer/tools/mac-release/release.sh"
[ -f "$SNAPSIFT_MAC_RELEASE" ] || die "SNAPSIFT_MAC_RELEASE does not exist: $SNAPSIFT_MAC_RELEASE (is the mac-release branch checked out?)"
[ -n "${SNAPSIFT_SU_PUBLIC_ED_KEY:-}" ] || die "SNAPSIFT_SU_PUBLIC_ED_KEY is not set — without it the build ships with updates OFF (see docs/UPDATES.md)"
[ -n "${SNAPSIFT_IDENTITY:-}" ] || die "SNAPSIFT_IDENTITY is not set (\"Developer ID Application: … (TEAMID)\")"
[ -f "$ENTITLEMENTS" ] || die "missing $ENTITLEMENTS"

# Monotonic build number: Sparkle compares CFBundleVersion, so a build number
# that does not exceed every one already in the feed is invisible to users.
if [ -f "$RELEASES_DIR/appcast.xml" ]; then
  newest="$(grep -o '<sparkle:version>[0-9][0-9.]*</sparkle:version>' "$RELEASES_DIR/appcast.xml" \
    | sed -E 's/<[^>]*>//g' | sort -n | tail -1 || true)"
  if [ -n "$newest" ] && ! [ "$BUILD" -gt "$newest" ] 2>/dev/null; then
    die "CFBundleVersion $BUILD (app/Info.plist) is not greater than the newest in $RELEASES_DIR/appcast.xml ($newest) — bump it, or installed copies will never see this update"
  fi
fi

echo "== snapsift $VERSION (build $BUILD) · feed $SNAPSIFT_FEED_URL =="
mkdir -p "$STAGE_DIR" "$RELEASES_DIR"
rm -rf "$APP"

# The build needs the Sparkle public key + feed URL (already exported/derived
# above); building into dist/stage keeps ~/Applications/snapsift.app untouched.
"$REPO_ROOT/app/scripts/build-app.sh" release "$APP"

if [ "$CMD" = check ]; then
  echo "▸ preflight only (nothing is signed)"
  exec bash "$SNAPSIFT_MAC_RELEASE" --preflight --app "$APP" --bundle-id "$BUNDLE_ID" \
    --identity "$SNAPSIFT_IDENTITY" --notary-profile "$NOTARY_PROFILE" --entitlements "$ENTITLEMENTS"
fi

bash "$SNAPSIFT_MAC_RELEASE" --preflight --app "$APP" --bundle-id "$BUNDLE_ID" \
  --identity "$SNAPSIFT_IDENTITY" --notary-profile "$NOTARY_PROFILE" --entitlements "$ENTITLEMENTS" \
  || die "preflight failed — fix the ✗ items above; nothing was signed"

bash "$SNAPSIFT_MAC_RELEASE" --app "$APP" --bundle-id "$BUNDLE_ID" \
  --identity "$SNAPSIFT_IDENTITY" --notary-profile "$NOTARY_PROFILE" \
  --entitlements "$ENTITLEMENTS" --out "$RELEASES_DIR" --version "$VERSION"

[ -f "$DMG" ] || die "expected $DMG after signing, not found"

# The dmg now holds the STAPLED app and must not be rebuilt or edited from here
# on: generate_appcast's EdDSA signature is over these exact bytes.
"$REPO_ROOT/scripts/make-appcast.sh" "$RELEASES_DIR"

grep -q "snapsift-$VERSION.dmg" "$RELEASES_DIR/appcast.xml" || die "appcast.xml has no entry for snapsift-$VERSION.dmg"

echo
echo "✓ release artifacts in $RELEASES_DIR"
echo "  Next (PUBLISH): SNAPSIFT_PUBLISH_DIR=<checkout serving $BASE_URL> scripts/release.sh publish"
echo "  then commit + push that checkout and curl -I the feed (docs/UPDATES.md ▸ Publish)."
