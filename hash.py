#!/usr/bin/env python3
r"""
snapsift / hash.py  (L3 — perceptual hashing)
=============================================

scan.py finds near-duplicates that are *adjacent in time* (manual bursts).
This pass finds the ones that aren't: the same photo saved twice on different
days — re-downloaded, screenshotted, AirDropped back, exported and re-imported.

How:
  1. For every candidate photo, load Apple's tiny `.THM` thumbnail from
     `derivatives/{uuid[0]}/{uuid}.THM` (no need to decode the HEIC original).
  2. Compute a 64-bit dHash (difference hash) of each thumbnail.
  3. Group photos whose hashes are within --max-distance Hamming bits, using a
     BK-tree so we don't compare every pair against every other (O(n log n)-ish
     instead of O(n²) on a six-figure library).
  4. Emit a groups.json-shaped file — so `pick.py` consumes it unchanged and
     all the same safety rules apply (favorites never deleted, quality keeper).

Pillow is the only extra dependency, and only for step 1/2:
    pip install "Pillow>=9"      # or: pip install snapsift[hash]

Usage:
    python3 hash.py --library ~/Pictures/Photos\ Library.photoslibrary \
                    --output hash-groups.json --max-distance 4

    python3 pick.py --input hash-groups.json --output hash-plan.json \
                    --uuid-out hash-delete-uuids.txt
"""

from __future__ import annotations
import argparse, json, sys
from dataclasses import asdict
from pathlib import Path

from scan import Photo, open_library, iter_assets  # reuse the read-only DB layer


# ── pure hashing helpers (no Pillow / no library needed — fully unit-tested) ──

def dhash_from_gray(pixels, size: int = 8) -> int:
    """64-bit difference hash from a flat row-major grayscale buffer that is
    (size+1) wide by `size` tall. Each bit is 'is this pixel brighter than the
    one to its right'. Robust to scaling, gamma and mild compression."""
    width = size + 1
    bits = 0
    for row in range(size):
        base = row * width
        for col in range(size):
            left = pixels[base + col]
            right = pixels[base + col + 1]
            bits = (bits << 1) | (1 if left > right else 0)
    return bits


def hamming(a: int, b: int) -> int:
    """Number of differing bits between two hashes."""
    return (a ^ b).bit_count() if hasattr(int, "bit_count") else bin(a ^ b).count("1")


class BKTree:
    """Metric tree over Hamming distance for fast 'all within d' queries."""

    def __init__(self):
        self.root = None  # (key, {distance: child})

    def add(self, key: int):
        if self.root is None:
            self.root = (key, {})
            return
        node = self.root
        while True:
            k, children = node
            d = hamming(key, k)
            child = children.get(d)
            if child is None:
                children[d] = (key, {})
                return
            node = child

    def query(self, key: int, max_distance: int) -> list[int]:
        if self.root is None:
            return []
        out, stack = [], [self.root]
        while stack:
            k, children = stack.pop()
            d = hamming(key, k)
            if d <= max_distance:
                out.append(k)
            for dist, child in children.items():
                if d - max_distance <= dist <= d + max_distance:
                    stack.append(child)
        return out


class _Union:
    """Tiny union-find keyed by arbitrary hashables."""

    def __init__(self):
        self.parent = {}

    def find(self, x):
        self.parent.setdefault(x, x)
        root = x
        while self.parent[root] != root:
            root = self.parent[root]
        while self.parent[x] != root:      # path compression
            self.parent[x], x = root, self.parent[x]
        return root

    def union(self, a, b):
        self.parent[self.find(a)] = self.find(b)


def group_by_hash(items, max_distance: int):
    """items: iterable of (hash:int, payload). Returns list of payload-lists,
    each a connected component (under Hamming<=max_distance) of size >= 2.

    Distinct payloads that share an identical hash always group together, even
    at max_distance=0 — that's the exact-thumbnail-match case."""
    by_hash: dict[int, list] = {}
    for h, payload in items:
        by_hash.setdefault(h, []).append(payload)

    tree = BKTree()
    for h in by_hash:
        tree.add(h)

    uf = _Union()
    for h in by_hash:
        for neighbour in tree.query(h, max_distance):
            uf.union(h, neighbour)

    components: dict[object, list] = {}
    for h, payloads in by_hash.items():
        components.setdefault(uf.find(h), []).extend(payloads)
    return [c for c in components.values() if len(c) >= 2]


# ── thumbnail IO (needs Pillow) ──────────────────────────────────────────────

def _load_pixels(thm_path: Path, size: int = 8):
    """Return a flat grayscale (size+1)×size buffer, or None if unreadable."""
    try:
        from PIL import Image  # lazy: only this path needs Pillow
    except ImportError:
        sys.exit("❌ This pass needs Pillow:  pip install \"Pillow>=9\"")
    try:
        with Image.open(thm_path) as im:
            small = im.convert("L").resize((size + 1, size), Image.BILINEAR)
            return list(small.getdata())
    except Exception:
        return None


def resolve_thumb(library: Path, uuid: str):
    """Locate a usable local thumbnail for an asset, or None.

    Apple stores per-asset renders under several schemes and — on
    "Optimize Mac Storage" libraries — only some are present locally. We try
    them cheapest-first: the standard masters render, then any sized render,
    then the video poster `.THM`.
    """
    b = uuid[0]
    deriv = library / "resources" / "derivatives"
    standard = deriv / "masters" / b / f"{uuid}_4_5005_c.jpeg"
    if standard.exists():                       # fast path: ~99% of photos
        return standard
    for folder in (deriv / "masters" / b, deriv / b):
        hits = sorted(folder.glob(f"{uuid}_*.jpeg"))
        if hits:
            return hits[-1]
    thm = deriv / b / f"{uuid}.THM"             # video poster frame
    return thm if thm.exists() else None


def hash_photos(library: Path, photos, size: int = 8, limit: int = 0,
                progress=lambda n, hashed, missing: None):
    """Yield (hash, Photo) for every photo whose thumbnail we can read."""
    seen = 0
    hashed = 0
    missing = 0
    for p in photos:
        seen += 1
        if limit and seen > limit:
            break
        thm = resolve_thumb(library, p.uuid)
        pixels = _load_pixels(thm, size) if thm else None
        if pixels is None:
            missing += 1
            continue
        hashed += 1
        if seen % 2000 == 0:
            progress(seen, hashed, missing)
        yield dhash_from_gray(pixels, size), p
    progress(seen, hashed, missing)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", type=Path,
                    default=Path.home() / "Pictures" / "Photos Library.photoslibrary")
    ap.add_argument("--output", type=Path, default=Path("hash-groups.json"))
    ap.add_argument("--max-distance", type=int, default=2,
                    help="Max Hamming distance (0-64) to call two thumbnails the "
                         "same. 0 = exact thumbnail match, 2 = near-identical "
                         "(default). Higher = more aggressive and more false "
                         "positives — always review via review.py before applying.")
    ap.add_argument("--include-video", action="store_true",
                    help="Also hash videos (uses their poster thumbnail)")
    ap.add_argument("--limit", type=int, default=0,
                    help="Only hash the first N assets (for a quick trial)")
    args = ap.parse_args()

    conn = open_library(args.library)
    photos = iter_assets(conn, include_video=args.include_video)

    cov = {"seen": 0, "hashed": 0, "missing": 0}

    def progress(seen, hashed, missing):
        cov.update(seen=seen, hashed=hashed, missing=missing)
        print(f"   …{seen:,} scanned, {hashed:,} hashed, {missing:,} no-thumbnail",
              end="\r", flush=True)

    pairs = list(hash_photos(args.library, photos, limit=args.limit, progress=progress))
    conn.close()
    print()
    if cov["missing"]:
        print(f"⚠️  {cov['missing']:,} of {cov['seen']:,} assets had no local "
              f"thumbnail and were skipped (likely evicted by iCloud "
              f"'Optimize Storage'). They are NOT in this plan.")

    groups = group_by_hash(pairs, args.max_distance)
    groups = [sorted(g, key=lambda p: p.taken_at) for g in groups]

    photo_count = sum(len(g) for g in groups)
    payload = {
        "library":      str(args.library),
        "mode":         "perceptual",
        "max_distance": args.max_distance,
        "include_video": args.include_video,
        "stats": {
            "groups":           len(groups),
            "candidate_photos": photo_count,
            "deletable":        photo_count - len(groups),
            "scanned":          cov["seen"],
            "hashed":           cov["hashed"],
            "no_thumbnail":     cov["missing"],
        },
        "groups": [
            {
                "size":     len(g),
                "span_sec": round(g[-1].taken_at - g[0].taken_at, 2),
                "photos":   [asdict(p) | {"taken_iso": p.taken_iso} for p in g],
            }
            for g in groups
        ],
    }
    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    print(f"✅ Wrote {args.output}")
    print(f"   {len(groups):,} perceptual clusters, {photo_count:,} photos, "
          f"{photo_count - len(groups):,} deletable")
    print(f"   → feed it to pick.py:  python3 pick.py --input {args.output}")


if __name__ == "__main__":
    main()
