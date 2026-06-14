#!/usr/bin/env bash
# Single entry point — the SAME checks .github/workflows/ci.yml runs.
# Python half runs anywhere with pytest + Pillow; the Swift half needs Xcode (macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ python tests"
python3 -c 'import pytest, PIL' 2>/dev/null || python3 -m pip install -q pytest "Pillow>=9"
python3 -m pytest -q

echo "→ swift build + tests (needs Xcode)"
( cd app && swift build && swift run SnapsiftTests )

echo "✅ ALL GREEN"
