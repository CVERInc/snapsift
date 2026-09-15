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


def _groups(**overrides):
    """A current-format groups.json: every photo carries the `edited` flag."""
    a = {"uuid": "A", "filename": "a", "taken_at": 0, "width": 1, "height": 1,
         "size": 1000, "uti": "public.heic", "kind": 0, "favorite": False,
         "quality": 0.25, "edited": False}
    b = {"uuid": "B", "filename": "b", "taken_at": 1, "width": 1, "height": 1,
         "size": 2000, "uti": "public.heic", "kind": 0, "favorite": False,
         "quality": 0.22, "edited": False}
    a.update(overrides.get("a", {}))
    b.update(overrides.get("b", {}))
    return {"groups": [{"size": 2, "span_sec": 1, "photos": [a, b]}]}


def test_pick_runs_end_to_end(tmp_path, capsys):
    groups = _groups()
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


# ── fail-closed on legacy input (CLI path) ───────────────────────────────────
# The dispatcher must not swallow a tool's exit code: a `snapsift pick` that
# REFUSED to write a delete list reported success for as long as it did.

def _legacy(tmp_path):
    """A pre-`edited` groups.json — what an older scan.py wrote."""
    groups = _groups()
    for p in groups["groups"][0]["photos"]:
        del p["edited"]
    path = tmp_path / "groups.json"
    path.write_text(json.dumps(groups))
    return path


def test_pick_via_cli_fails_closed_on_legacy_groups(tmp_path, capsys):
    gpath = _legacy(tmp_path)
    plan = tmp_path / "plan.json"
    uuids = tmp_path / "del.txt"
    rc = cli.main(["pick", "--input", str(gpath), "--output", str(plan),
                   "--uuid-out", str(uuids)])
    assert rc != 0                     # the dispatcher propagates the refusal
    assert not uuids.exists()          # and no delete list was written
    assert not plan.exists()


def test_pick_via_cli_legacy_flag_opts_in(tmp_path, capsys):
    gpath = _legacy(tmp_path)
    plan = tmp_path / "plan.json"
    uuids = tmp_path / "del.txt"
    rc = cli.main(["pick", "--input", str(gpath), "--output", str(plan),
                   "--uuid-out", str(uuids), "--allow-legacy-groups"])
    assert rc == 0
    assert uuids.read_text().split() == ["B"]
    err = capsys.readouterr().err
    assert "FAVORITES ONLY" in err
