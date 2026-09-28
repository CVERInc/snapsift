"""The INSTALLED `snapsift` console command, not the source checkout.

Every other test imports the flat modules straight from the repo root, where
delete.applescript happens to sit next to cli.py — so a wheel that forgets to
ship it still passes them all. These tests `pip install` the project into a
throwaway venv and drive the real console entry point from outside the repo,
which is what a user following the README's "If you `pip install .`" does.

`osascript` is replaced by a stub on PATH that records its argv, so this runs
on any OS and never touches Photos."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent


def _bin(venv: Path, name: str) -> Path:
    return venv / ("Scripts" if os.name == "nt" else "bin") / name


@pytest.fixture(scope="module")
def installed(tmp_path_factory):
    """A fresh venv with the project installed (non-editable) from a clean copy
    of the source tree, so stale build/ output in the checkout can't leak in."""
    root = tmp_path_factory.mktemp("pkg")
    src = root / "src"
    shutil.copytree(REPO, src, ignore=shutil.ignore_patterns(
        ".git", "app", "tests", "docs", "build", "dist", "*.egg-info",
        ".venv*", "venv", "__pycache__"))
    venv = root / "venv"
    subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    subprocess.run([str(_bin(venv, "python")), "-m", "pip", "install", "-q",
                    "--disable-pip-version-check", str(src)], check=True)
    return venv


def _run(installed, tmp_path, *args, path_prefix=None):
    env = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    if path_prefix:
        env["PATH"] = f"{path_prefix}{os.pathsep}{env.get('PATH', '')}"
    return subprocess.run([str(_bin(installed, "snapsift")), *args],
                          cwd=tmp_path, env=env, capture_output=True, text=True)


def test_installed_entry_point_dispatches(installed, tmp_path):
    r = _run(installed, tmp_path, "--help")
    assert r.returncode == 0, r.stderr
    for cmd in ("scan", "pick", "delete", "hash", "review"):
        assert cmd in r.stdout
    r = _run(installed, tmp_path, "pick", "--help")
    assert r.returncode == 0, r.stderr
    assert "--uuid-out" in r.stdout


@pytest.mark.skipif(os.name == "nt", reason="osascript stub is a POSIX shell script")
def test_installed_delete_finds_its_applescript(installed, tmp_path):
    stub_dir = tmp_path / "stub"
    stub_dir.mkdir()
    log = tmp_path / "osascript.argv"
    stub = stub_dir / "osascript"
    stub.write_text(f'#!/bin/sh\nfor a in "$@"; do echo "$a"; done > "{log}"\n')
    stub.chmod(0o755)
    (tmp_path / "u.txt").write_text("UUID-1\n")

    r = _run(installed, tmp_path, "delete", "u.txt", path_prefix=stub_dir)

    assert r.returncode == 0, r.stderr
    argv = log.read_text().splitlines()
    assert argv[1:] == ["u.txt"]
    script = Path(argv[0])
    # The shipped copy, not the checkout's — and byte-identical to it.
    assert REPO not in script.parents
    assert script.read_bytes() == (REPO / "delete.applescript").read_bytes()
