"""Keeper / delete-selection logic from pick.py — favorites are sacred."""
import pytest
from pick import keeper, rank, quality_bucket, is_protected


def ph(uuid, *, uti="public.jpeg", size=1_000_000, taken_at=0.0,
       fav=False, quality=0.0, edited=False, is_document=False,
       sharpness=0.0, original_camera=False):
    return {"uuid": uuid, "uti": uti, "size": size, "taken_at": taken_at,
            "favorite": fav, "quality": quality, "edited": edited,
            "is_document": is_document, "sharpness": sharpness,
            "original_camera": original_camera}


def deletes(group):
    # Mirrors pick.main()'s production rule exactly: a frame is deleted only if
    # it is neither the keeper nor protected (favorite / edited / document).
    keep = keeper(group)
    return [p for p in group
            if p["uuid"] != keep["uuid"] and not is_protected(p)]


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


# ── expanded protection class (slice 1) ──────────────────────────────────────
# A photo must NEVER be in deletions if it is favorite OR edited OR a document.
# False-positive over-protection is the SAFE direction; the #1 rule is to never
# mark a frame a human likely wants to keep.

def test_edited_frame_is_never_deleted():
    keep = ph("a", uti="public.heic", size=9_000_000)
    edited = ph("b", edited=True)           # user adjusted it → sacred
    junk = ph("c")
    deleted = {d["uuid"] for d in deletes([keep, edited, junk])}
    assert "b" not in deleted               # edited survives even as non-keeper
    assert "c" in deleted


def test_document_frame_is_never_deleted():
    keep = ph("a", uti="public.heic", size=9_000_000)
    doc = ph("b", is_document=True)         # scan / receipt / ID → kept deliberately
    junk = ph("c")
    deleted = {d["uuid"] for d in deletes([keep, doc, junk])}
    assert "b" not in deleted
    assert "c" in deleted


def test_all_protected_cluster_deletes_nothing():
    group = [ph("a", edited=True), ph("b", is_document=True)]
    assert deletes(group) == []


# ── sharpness is a within-group ranking signal ONLY (slice 1) ────────────────
# Blur orders the keeper within a real multi-frame group; it must NEVER be a
# standalone delete trigger and must NEVER grow the deletion set.

def test_sharper_frame_is_keeper_within_group():
    blur = ph("a", sharpness=0.2)
    sharp = ph("b", sharpness=0.9)
    assert keeper([blur, sharp])["uuid"] == "b"


def test_sharpness_does_not_override_quality():
    good = ph("a", uti="public.heic", quality=0.9, sharpness=0.0)
    sharp_but_worse = ph("b", uti="public.jpeg", quality=0.1, sharpness=1.0)
    assert keeper([good, sharp_but_worse])["uuid"] == "a"


def test_lone_blurry_photo_is_never_deleted():
    # A single-member group produces zero deletions, blur or not.
    assert deletes([ph("a", sharpness=0.0)]) == []


def test_blur_reorders_keeper_but_never_grows_deletions():
    # Same two frames, sharpness swapped → the deletion COUNT is identical (one
    # non-keeper either way); blur only changes *which* frame is kept.
    sharp_keeper = {d["uuid"] for d in deletes(
        [ph("a", taken_at=0.0, sharpness=0.9), ph("b", taken_at=1.0, sharpness=0.1)])}
    blur_keeper = {d["uuid"] for d in deletes(
        [ph("a", taken_at=0.0, sharpness=0.1), ph("b", taken_at=1.0, sharpness=0.9)])}
    assert sharp_keeper == {"b"} and blur_keeper == {"a"}


# ── social re-save vs original camera capture (slice 1) ──────────────────────
# Prefer the frame with original camera metadata over an EXIF-stripped social
# re-save, even when the re-save is newer / larger. newer != better.

def test_original_camera_beats_larger_social_resave():
    original = ph("a", size=1_000_000, taken_at=0.0, original_camera=True)
    resave = ph("b", size=5_000_000, taken_at=1.0, original_camera=False)
    assert keeper([original, resave])["uuid"] == "a"


def test_edited_social_resave_is_still_protected():
    original = ph("a", original_camera=True)
    edited_resave = ph("b", original_camera=False, edited=True)
    deleted = {d["uuid"] for d in deletes([original, edited_resave])}
    assert "b" not in deleted


def test_original_camera_all_false_falls_through_to_size():
    # PENDING (originalCamera App detection): the app's PhotoFlags.originalCamera()
    # still returns False (no cheap on-device EXIF Make/Model yet — see its TODO),
    # so in practice every frame is original_camera=False and the signal is a
    # no-op that falls through to format/size — never a delete trigger, so safe.
    # This pins that all-false fallback; flip it when the App detector lands.
    big = ph("a", size=5_000_000, original_camera=False)
    small = ph("b", size=1_000_000, original_camera=False)
    assert keeper([big, small])["uuid"] == "a"


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
