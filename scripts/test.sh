#!/usr/bin/env bash
# Single entry point — the SAME checks .github/workflows/ci.yml runs.
# Python half runs anywhere with pytest + Pillow; Swift needs macOS, and the
# iOS library check needs Xcode with the iPhoneOS SDK installed.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ python tests"
# Prefer the system interpreter when prerequisites already exist; otherwise
# install only in a project-local venv, never into the machine's Python.
PY=python3
if ! "$PY" -c 'import pytest, PIL' 2>/dev/null; then
    [ -x .venv-test/bin/python ] || "$PY" -m venv .venv-test
    .venv-test/bin/python -m pip install -q pytest "Pillow>=9"
    PY=.venv-test/bin/python
fi
"$PY" -m pytest -q

echo "→ swift build + tests (needs Xcode)"
( cd app && nice -n 10 swift build -j 3 && nice -n 10 swift run -j 3 SnapsiftTests )

if command -v xcodebuild >/dev/null 2>&1 \
    && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "→ iOS library builds (generic device, no signing)"
    nice -n 10 ./scripts/build-ios-libraries.sh -jobs 3
else
    echo "→ skipping iOS library builds: Xcode/iPhoneOS SDK unavailable locally"
fi

echo "✅ ALL GREEN"
