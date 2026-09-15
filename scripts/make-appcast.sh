#!/usr/bin/env bash
# scripts/make-appcast.sh — wraps Sparkle's own `generate_appcast` tool: point
# it at a directory of built release .dmg/.zip files and it (re)writes
# appcast.xml there, signing each entry with the EdDSA key it finds via the
# `generate_appcast` binary itself (Keychain, account "ed25519" by default —
# the same account `generate_keys` writes to).
#
#   scripts/make-appcast.sh <releases-dir> [extra generate_appcast args...]
#
#   <releases-dir>   Directory holding every release archive you want in the
#                     feed (not just the newest — generate_appcast rewrites
#                     the whole appcast.xml from what's in this directory each
#                     run; see its own --help for --versions / --maximum-versions
#                     if you need to prune or backfill). appcast.xml is
#                     written into this same directory, matching Sparkle's
#                     default (an existing one there is updated in place).
#   extra args        Forwarded verbatim to generate_appcast — e.g.
#                     `--channel beta`, `-o custom-name.xml`.
#
# ── one-time setup (a human does this, NOT this script) ─────────────────
#
#   1. Download the SAME Sparkle release this repo pins (see the
#      SPARKLE_TAG line below / app/Package.swift) and run its
#      bin/generate_keys ONCE, by hand, on the machine that will run this
#      script. It creates an EdDSA (ed25519) key pair and stores the PRIVATE
#      half in this Mac's LOGIN KEYCHAIN under account "ed25519" — it does
#      not write the private key to disk. It prints the PUBLIC half once;
#      save that.
#      🔴 Do NOT run generate_keys from this script or any automated context
#      — it is a one-time human credential-creation step. This script only
#      ever calls generate_appcast, which READS the key generate_keys already
#      stored, never creates one.
#   2. Put the printed public key in SNAPSIFT_SU_PUBLIC_ED_KEY when you run
#      app/scripts/build-app.sh — it becomes the shipped Info.plist's
#      SUPublicEDKey, which is what lets a running snapsift verify that an
#      appcast this script signed is genuine. See docs/UPDATES.md for the
#      full release sequence (build-app.sh → mac-release/release.sh →
#      make-appcast.sh → upload).
#   3. generate_appcast (what this script wraps) reads the PRIVATE key back
#      out of the Keychain by that same account name and signs each archive
#      with it. If generate_keys was never run, or ran under a different
#      account, generate_appcast fails loudly rather than silently skipping
#      the signature — nothing here papers over that.
#
# generate_appcast itself is downloaded into a scratch dir under THIS
# worktree's .build/ (never installed globally, never committed), pinned to
# the exact Sparkle release tag app/Package.swift pins, so the appcast format
# always matches what the shipped Sparkle.framework expects.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_TAG="$(grep -m1 'sparkle-project/Sparkle' app/Package.swift | sed -E 's/.*exact: *"([^"]+)".*/\1/')"
if [ -z "$SPARKLE_TAG" ]; then
  echo "✗ could not read the pinned Sparkle tag out of app/Package.swift (expected a .package(url: \".../Sparkle\", exact: \"X.Y.Z\") line)" >&2
  exit 1
fi

RELEASES_DIR="${1:-}"
if [ -z "$RELEASES_DIR" ]; then
  echo "Usage: $0 <releases-dir> [extra generate_appcast args...]" >&2
  exit 2
fi
if [ ! -d "$RELEASES_DIR" ]; then
  echo "✗ not a directory: $RELEASES_DIR" >&2
  exit 2
fi
shift

DOWNLOAD_URL_PREFIX="${SNAPSIFT_DOWNLOAD_URL_PREFIX:-https://oss.cver.net/snapsift/}"

SCRATCH=".build/sparkle-tools/$SPARKLE_TAG"
BIN_DIR="$SCRATCH/bin"
if [ ! -x "$BIN_DIR/generate_appcast" ]; then
  echo "▸ fetching Sparkle $SPARKLE_TAG release tools (generate_appcast) into $SCRATCH"
  mkdir -p "$SCRATCH"
  ASSET_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_TAG/Sparkle-$SPARKLE_TAG.tar.xz"
  TARBALL="$SCRATCH/Sparkle-$SPARKLE_TAG.tar.xz"
  curl -fsSL -o "$TARBALL" "$ASSET_URL"
  tar -xf "$TARBALL" -C "$SCRATCH"
  rm -f "$TARBALL"
fi
if [ ! -x "$BIN_DIR/generate_appcast" ]; then
  echo "✗ generate_appcast still not found under $BIN_DIR after extracting the release archive — Sparkle's release layout may have changed. Check $SCRATCH by hand." >&2
  exit 1
fi

echo "▸ $BIN_DIR/generate_appcast --download-url-prefix $DOWNLOAD_URL_PREFIX $RELEASES_DIR $*"
"$BIN_DIR/generate_appcast" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$@" "$RELEASES_DIR"

echo "✓ appcast.xml written under $RELEASES_DIR"
