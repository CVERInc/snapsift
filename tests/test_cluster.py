"""Clustering logic — the heart of scan.py. No real library needed."""
from scan import Photo, cluster, quality_score


def p(pk, taken_at, *, w=4032, h=3024, size=2_000_000, uti="public.heic",
      kind=0, fav=False, quality=0.0):
    """Build a Photo with sensible burst-frame defaults."""
    return Photo(pk=pk, uuid=f"U{pk}", filename=f"IMG_{pk}.heic",
                 taken_at=float(taken_at), width=w, height=h, size=size,
                 uti=uti, kind=kind, favorite=fav, quality=quality)


def sizes(groups):
    return [len(g) for g in groups]


def test_basic_burst_clusters():
    photos = [p(1, 0), p(2, 1), p(3, 2), p(4, 100), p(5, 101)]
    groups = list(cluster(photos, gap_sec=3, size_tol=0.10))
    assert sizes(groups) == [3, 2]


def test_singletons_are_dropped():
    photos = [p(1, 0), p(2, 50), p(3, 100)]   # all far apart
    assert list(cluster(photos, gap_sec=3, size_tol=0.10)) == []


def test_dimension_change_splits():
    photos = [p(1, 0), p(2, 1, w=100, h=100), p(3, 2, w=100, h=100)]
    groups = list(cluster(photos, gap_sec=3, size_tol=0.10))
    assert sizes(groups) == [2]            # frames 2 & 3; frame 1 is a singleton


def test_size_tolerance_splits():
    # frame 2 is 50% larger than frame 1 → outside ±10%
    photos = [p(1, 0, size=1_000_000), p(2, 1, size=1_500_000), p(3, 2, size=1_510_000)]
    groups = list(cluster(photos, gap_sec=3, size_tol=0.10))
    assert sizes(groups) == [2]            # frames 2 & 3

def test_zero_size_is_permissive():
    # missing original size (0) must not crash the divide and should pass
    photos = [p(1, 0, size=0), p(2, 1, size=0)]
    assert sizes(list(cluster(photos, gap_sec=3, size_tol=0.10))) == [2]


def test_max_span_caps_chained_drift():
    # 1s gaps chain forever; first→last spans 5s. max_span=2 must break it up.
    photos = [p(i, i) for i in range(6)]
    loose = list(cluster(photos, gap_sec=3, size_tol=0.10, max_span=0))
    assert sizes(loose) == [6]
    capped = list(cluster(photos, gap_sec=3, size_tol=0.10, max_span=2))
    # each cluster bounded to a 2s span → 0,1,2 then 3,4,5
    assert all((g[-1].taken_at - g[0].taken_at) <= 2 for g in capped)
    assert sum(sizes(capped)) <= 6 and len(capped) >= 2


def test_quality_score_positive_minus_negative():
    s = quality_score({"sharply_focused": 0.9, "well_framed": 0.8,
                       "noise": 0.3, "failure": 0.1})
    assert s == round(0.9 + 0.8 - 0.3 - 0.1, 4)


def test_quality_score_handles_none():
    assert quality_score({"sharply_focused": None, "noise": None}) == 0.0
    assert quality_score({}) == 0.0
