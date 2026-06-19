"""review.py group-annotation logic (no server / no library needed)."""
import json
from review import build_groups


def _groups_file(tmp_path, groups):
    f = tmp_path / "groups.json"
    f.write_text(json.dumps({"groups": groups}))
    return f


def _photo(uuid, **kw):
    base = {"uuid": uuid, "filename": f"IMG_{uuid}.heic", "uti": "public.heic",
            "size": 1_000_000, "taken_at": 0.0, "favorite": False, "quality": 0.0,
            "taken_iso": "2026-01-01T00:00:00+00:00"}
    base.update(kw)
    return base


def test_marks_exactly_one_keeper(tmp_path):
    g = [{"size": 3, "span_sec": 2, "photos": [
        _photo("a", quality=0.2),
        _photo("b", quality=0.9),     # best quality → keeper
        _photo("c", quality=0.1),
    ]}]
    out = build_groups(_groups_file(tmp_path, g))
    keepers = [p for p in out[0]["photos"] if p["is_keeper"]]
    assert len(keepers) == 1 and keepers[0]["uuid"] == "b"


def test_favorite_flag_passthrough(tmp_path):
    g = [{"size": 2, "span_sec": 1, "photos": [
        _photo("a", favorite=True, size=1),
        _photo("b", size=9_000_000),
    ]}]
    out = build_groups(_groups_file(tmp_path, g))
    fav = next(p for p in out[0]["photos"] if p["uuid"] == "a")
    assert fav["favorite"] is True and fav["is_keeper"] is True


def test_shape_is_minimal_and_serialisable(tmp_path):
    g = [{"size": 2, "span_sec": 1, "photos": [_photo("a"), _photo("b")]}]
    out = build_groups(_groups_file(tmp_path, g))
    json.dumps(out)                    # must be JSON-serialisable for the API
    assert set(out[0]["photos"][0]) == {
        "uuid", "filename", "uti", "favorite", "protected", "quality",
        "taken_iso", "is_keeper"}


def test_protected_flag_covers_edited_and_document(tmp_path):
    # The review UI's delete guard keys off `protected` (favorite/edited/
    # document), so build_groups must surface it for each photo. A protected
    # frame must never be a candidate for the export list.
    g = [{"size": 4, "span_sec": 1, "photos": [
        _photo("a", quality=0.9),                 # plain keeper
        _photo("b", favorite=True),               # protected: favorite
        _photo("c", edited=True),                 # protected: edited
        _photo("d", is_document=True),            # protected: document
    ]}]
    out = build_groups(_groups_file(tmp_path, g))
    by = {p["uuid"]: p for p in out[0]["photos"]}
    assert by["a"]["protected"] is False
    assert by["b"]["protected"] and by["c"]["protected"] and by["d"]["protected"]
