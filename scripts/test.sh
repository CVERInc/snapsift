#!/usr/bin/env bash
# Single entry point — the SAME checks .github/workflows/ci.yml runs.
# Python half runs anywhere with pytest + Pillow; the Swift half needs Xcode (macOS).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ python tests"
# Prefer the system interpreter; when it lacks pytest/Pillow and refuses
# `pip install` (PEP 668 externally-managed, e.g. Homebrew Python), fall
# back to a project-local venv at .venv-test (created once, reused after).
PY=python3
if ! "$PY" -c 'import pytest, PIL' 2>/dev/null; then
    if ! "$PY" -m pip install -q pytest "Pillow>=9" 2>/dev/null; then
        [ -x .venv-test/bin/python ] || "$PY" -m venv .venv-test
        .venv-test/bin/python -m pip install -q pytest "Pillow>=9"
        PY=.venv-test/bin/python
    fi
fi
"$PY" -m pytest -q

echo "→ swift build + tests (needs Xcode)"
( cd app && swift build && swift run SnapsiftTests )

echo "✅ ALL GREEN"
