"""L3 perceptual-hash logic. Pure parts need no library; the IO test uses Pillow."""
import pytest
from hash import dhash_from_gray, hamming, BKTree, group_by_hash, _load_pixels

PIL = pytest.importorskip("PIL", reason="Pillow needed for thumbnail IO tests")


# ── pure logic ────────────────────────────────────────────────────────────

def test_hamming_basics():
    assert hamming(0b1010, 0b1010) == 0
    assert hamming(0b1010, 0b1000) == 1
    assert hamming(0, 0xFFFFFFFFFFFFFFFF) == 64


def test_dhash_left_brighter_gives_one_bits():
    # 9x8 buffer where every pixel is brighter than the one to its right
    grad = [255 - col for row in range(8) for col in range(9)]
    assert dhash_from_gray(grad) == (1 << 64) - 1   # all 64 bits set


def test_dhash_flat_image_is_zero():
    flat = [128] * (9 * 8)
    assert dhash_from_gray(flat) == 0


def test_bktree_query_within_distance():
    t = BKTree()
    for h in (0b0000, 0b0001, 0b0011, 0b1111):
        t.add(h)
    near = set(t.query(0b0000, 1))
    assert near == {0b0000, 0b0001}            # 0011 is distance 2, 1111 is 4


def test_group_by_hash_exact_match():
    items = [(100, "a"), (100, "b"), (200, "c")]
    groups = group_by_hash(items, max_distance=0)
    assert len(groups) == 1
    assert set(groups[0]) == {"a", "b"}        # c is a singleton, dropped


def test_group_by_hash_near_match_transitive():
    # a~b (d=1), b~c (d=1), a~c (d=2): with max_distance=1 they still chain
    items = [(0b000, "a"), (0b001, "b"), (0b011, "c"), (0b111111, "z")]
    groups = group_by_hash(items, max_distance=1)
    assert len(groups) == 1
    assert set(groups[0]) == {"a", "b", "c"}   # z is far away


def test_group_by_hash_distance_zero_keeps_distinct():
    items = [(1, "a"), (2, "b")]               # 1 bit apart
    assert group_by_hash(items, max_distance=0) == []


# ── thumbnail IO (Pillow) ───────────────────────────────────────────────────

def _save(tmp_path, name, color_fn):
    from PIL import Image
    im = Image.new("RGB", (64, 64))
    im.putdata([color_fn(x, y) for y in range(64) for x in range(64)])
    path = tmp_path / name
    im.save(path, "JPEG", quality=90)
    return path


def test_load_and_hash_roundtrip_groups_similar(tmp_path):
    # two near-identical gradients vs one inverted image
    grad   = _save(tmp_path, "a.jpg", lambda x, y: (x * 4, x * 4, x * 4))
    grad2  = _save(tmp_path, "b.jpg", lambda x, y: (min(255, x * 4 + 6),) * 3)
    invert = _save(tmp_path, "z.jpg", lambda x, y: (255 - x * 4,) * 3)

    ha = dhash_from_gray(_load_pixels(grad))
    hb = dhash_from_gray(_load_pixels(grad2))
    hz = dhash_from_gray(_load_pixels(invert))

    assert hamming(ha, hb) <= 4                # the two gradients are close
    groups = group_by_hash([(ha, "a"), (hb, "b"), (hz, "z")], max_distance=4)
    assert len(groups) == 1 and set(groups[0]) == {"a", "b"}


def test_load_pixels_missing_file_returns_none(tmp_path):
    assert _load_pixels(tmp_path / "nope.THM") is None
