#!/usr/bin/env bash
# Build every public root library for iOS without signing or a simulator.
# The root package scheme includes all library products in Package.swift.
# Extra arguments pass through to xcodebuild (e.g. -jobs N).
set -euo pipefail
cd "$(dirname "$0")/.."

trap 'rm -rf ./.dd' EXIT
xcodebuild -scheme snapsift-Package \
    -destination 'generic/platform=iOS' \
    -derivedDataPath ./.dd build CODE_SIGNING_ALLOWED=NO "$@"
