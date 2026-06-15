"""Keeper / delete-selection logic from pick.py — favorites are sacred."""
import pytest
from pick import keeper, rank, quality_bucket


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


# ── quality quantisation: must match the Swift app exactly ───────────────────
# These pin the SHARED round-half-up rule (floor(q*10 + 0.5)). Python's old
# round(q, 1) used banker's rounding (0.25 → 0.2) while Swift's .rounded() used
# round-half-away (0.25 → 0.3), so the CLI and the app could pick DIFFERENT
# keepers on a half-tenth quality boundary. The bucket must be the same integer
# on both sides; Swift's mirror lives in app/.../SnapsiftCore/Keeper.swift.

def test_quality_bucket_round_half_up_matches_swift():
    # The exact half-boundaries where banker's vs away-from-zero diverged.
    assert quality_bucket(0.05) == 1
    assert quality_bucket(0.15) == 2
    assert quality_bucket(0.25) == 3     # banker's round() gave 0.2 → 2 (the bug)
    assert quality_bucket(0.35) == 4
    assert quality_bucket(0.45) == 5
    assert quality_bucket(-0.15) == -1
    assert quality_bucket(0.0) == 0
    assert quality_bucket(None) == 0


def test_keeper_half_boundary_quality_is_deterministic():
    # Reproduces the cross-impl keeper disagreement: under the OLD code Python
    # bucketed 0.25 and 0.22 both to 0.2 (tie → larger 'b' won) while Swift put
    # 0.25 in a higher bucket ('a' won). The shared rule now buckets 0.25 → 3,
    # 0.22 → 2, so BOTH keep 'a' — one answer, no platform split.
    a = ph("a", uti="public.heic", size=1_000_000, taken_at=0.0, quality=0.25)
    b = ph("b", uti="public.heic", size=2_000_000, taken_at=1.0, quality=0.22)
    assert keeper([a, b])["uuid"] == "a"
