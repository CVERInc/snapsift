"""The single `snapsift` console entry point (cli.py) — a thin dispatcher.

We verify it routes to each tool and forwards args, without touching a real
Photos library: `pick` runs fully on a synthetic groups.json, and the others
are exercised via --help (which argparse turns into a SystemExit(0))."""
import json

import cli


def test_top_help_lists_every_command(capsys):
    rc = cli.main(["--help"])
    out = capsys.readouterr().out
    assert rc == 0
    for cmd in ("scan", "pick", "delete", "hash", "review"):
        assert cmd in out


def test_unknown_command_is_error(capsys):
    assert cli.main(["nope"]) == 2
    assert "unknown command" in capsys.readouterr().err


def test_subcommand_help_forwards_to_tool(capsys):
    # argparse --help exits 0 and prints that tool's own option list.
    assert cli.main(["scan", "--help"]) == 0
    assert "--gap-sec" in capsys.readouterr().out


def test_pick_runs_end_to_end(tmp_path, capsys):
    groups = {"groups": [{"size": 2, "span_sec": 1, "photos": [
        {"uuid": "A", "filename": "a", "taken_at": 0, "width": 1, "height": 1,
         "size": 1000, "uti": "public.heic", "kind": 0, "favorite": False, "quality": 0.25},
        {"uuid": "B", "filename": "b", "taken_at": 1, "width": 1, "height": 1,
         "size": 2000, "uti": "public.heic", "kind": 0, "favorite": False, "quality": 0.22},
    ]}]}
    gpath = tmp_path / "groups.json"
    gpath.write_text(json.dumps(groups))
    plan = tmp_path / "plan.json"
    uuids = tmp_path / "del.txt"

    rc = cli.main(["pick", "--input", str(gpath), "--output", str(plan),
                   "--uuid-out", str(uuids)])
    assert rc == 0
    # Deterministic half-boundary keeper: A stays, B is the delete.
    assert uuids.read_text().split() == ["B"]
    assert json.loads(plan.read_text())["groups"][0]["keep"]["uuid"] == "A"


def test_delete_help_does_not_invoke_osascript(capsys):
    # No args / --help must NOT shell out; it just prints usage.
    assert cli.main(["delete", "--help"]) == 0
    assert "Recently Deleted" in capsys.readouterr().out
