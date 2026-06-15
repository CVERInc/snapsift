#!/usr/bin/env python3
"""
snapsift — single console entry point
=====================================

Wraps the five small tools behind one `snapsift` command so the whole pipeline
is discoverable from `snapsift --help` instead of four separate scripts:

    snapsift scan    …   # scan.py    — time-burst clusters → groups.json
    snapsift pick    …   # pick.py    — choose keepers       → plan.json + uuids
    snapsift delete  …   # delete.applescript via osascript  — move to Recently Deleted
    snapsift hash    …   # hash.py    — L3 cross-time perceptual pass
    snapsift review  …   # review.py  — local web UI to eyeball before deleting

Every subcommand forwards its remaining arguments verbatim to the underlying
tool, so `snapsift scan --gap-sec 5` behaves exactly like `python3 scan.py
--gap-sec 5`. This is a thin dispatcher — zero new behaviour, zero new deps.
"""

from __future__ import annotations
import subprocess
import sys
from pathlib import Path

# Subcommands backed by an importable module with a main() that reads sys.argv.
_MODULE_COMMANDS = {
    "scan":   ("scan",   "Find time-burst near-duplicate clusters (groups.json)"),
    "pick":   ("pick",   "Choose one keeper per cluster (plan.json + delete-uuids.txt)"),
    "hash":   ("hash",   "L3 cross-time perceptual pass (needs Pillow)"),
    "review": ("review", "Local web UI to review clusters before deleting"),
}

_USAGE = """usage: snapsift <command> [options]

commands:
  scan      Find time-burst near-duplicate clusters (groups.json)
  pick      Choose one keeper per cluster (plan.json + delete-uuids.txt)
  delete    Move the planned UUIDs to Recently Deleted (via Photos.app)
  hash      L3 cross-time perceptual pass (needs Pillow)
  review    Local web UI to review clusters before deleting

Run `snapsift <command> --help` for that command's options.
"""

_ROOT = Path(__file__).resolve().parent


def _run_module(module_name: str, argv: list[str]) -> int:
    """Invoke a tool's main() with a rewritten argv, so its argparse prints the
    real script's options and `prog` stays sensible under the subcommand."""
    import importlib

    mod = importlib.import_module(module_name)
    saved = sys.argv
    sys.argv = [f"snapsift {module_name}"] + argv
    try:
        mod.main()
        return 0
    except SystemExit as e:                       # argparse --help / errors
        return int(e.code) if isinstance(e.code, int) else (0 if e.code is None else 1)
    finally:
        sys.argv = saved


def _run_delete(argv: list[str]) -> int:
    """`delete` is an AppleScript, not a Python module — shell out to osascript.
    Forwards the uuid-file path (and any extra args) straight through."""
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: snapsift delete <delete-uuids.txt>\n\n"
              "Moves every listed UUID to Photos' Recently Deleted (recoverable\n"
              "30 days), in batches. Photos.app must be running.")
        return 0
    script = _ROOT / "delete.applescript"
    if not script.exists():
        print(f"❌ missing {script}", file=sys.stderr)
        return 1
    return subprocess.call(["osascript", str(script), *argv])


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help"):
        print(_USAGE)
        return 0

    cmd, rest = argv[0], argv[1:]
    if cmd == "delete":
        return _run_delete(rest)
    if cmd in _MODULE_COMMANDS:
        return _run_module(_MODULE_COMMANDS[cmd][0], rest)

    print(f"❌ unknown command: {cmd}\n", file=sys.stderr)
    print(_USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
