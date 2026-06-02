"""Keeper / delete-selection logic from pick.py — favorites are sacred."""
import pytest
from pick import keeper, rank


def ph(uuid, *, uti="public.jpeg", size=1_000_000, taken_at=0.0,
       fav=False, quality=0.0):
    return {"uuid": uuid, "uti": uti, "size": size, "taken_at": taken_at,
            "favorite": fav, "quality": quality}


def deletes(group):
    keep = keeper(group)
    return [p for p in group
            if p["uuid"] != keep["uuid"] and not p.get("favorite")]


def test_format_priority_beats_size():
    # HEIC wins over a much larger JPEG
    heic = ph("a", uti="public.heic", size=1_000_000)
    jpg  = ph("b", uti="public.jpeg", size=9_000_000)
    assert keeper([heic, jpg])["uuid"] == "a"


def test_quality_outranks_format():
    # a high-quality JPEG beats a low-quality HEIC
    sharp_jpg = ph("a", uti="public.jpeg", quality=2.0)
    dull_heic = ph("b", uti="public.heic", quality=0.1)
    assert keeper([sharp_jpg, dull_heic])["uuid"] == "a"


def test_quality_ties_fall_through_to_format():
    # near-identical quality → format tiebreaker decides, not noise
    a = ph("a", uti="public.jpeg", quality=1.02)
    b = ph("b", uti="public.heic", quality=1.01)
    assert keeper([a, b])["uuid"] == "b"   # HEIC wins the rounded tie


def test_size_breaks_format_tie():
    small = ph("a", uti="public.heic", size=1_000_000)
    big   = ph("b", uti="public.heic", size=5_000_000)
    assert keeper([small, big])["uuid"] == "b"


def test_favorite_is_always_keeper():
    fav  = ph("a", uti="public.jpeg", size=1, fav=True)
    big  = ph("b", uti="public.heic", size=9_000_000)
    assert keeper([fav, big])["uuid"] == "a"


def test_favorites_are_never_deleted():
    fav  = ph("a", fav=True)
    keep = ph("b", uti="public.heic", size=9_000_000)
    junk = ph("c")
    out = deletes([keep, fav, junk])
    deleted = {d["uuid"] for d in out}
    assert "a" not in deleted          # favorite survives even as non-keeper
    assert "c" in deleted


def test_all_favorite_cluster_deletes_nothing():
    group = [ph("a", fav=True), ph("b", fav=True)]
    assert deletes(group) == []


def test_rank_is_total_order():
    # rank must return comparable tuples for max()/sorted()
    group = [ph("a", quality=0.5), ph("b", quality=0.9), ph("c", fav=True)]
    assert sorted(group, key=rank)[-1]["uuid"] == "c"
