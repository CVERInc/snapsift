#!/usr/bin/env python3
"""
snapsift / scan.py
===================

Reads an Apple Photos library SQLite database and finds *near-duplicate*
groups that Photos.app's built-in Duplicates detector misses — specifically
"manual burst" sequences where someone held the shutter and got many
near-identical shots.

Strategy:
  1. Open Photos.sqlite read-only (immutable=1) so we don't disturb a
     running Photos.app.
  2. Walk every (non-trashed, non-hidden) asset in date order.
  3. Group consecutive photos that share (width, height) AND were taken
     within --gap-sec of the previous one AND have file size within
     --size-tolerance.
  4. Emit groups.json with one record per cluster, containing every
     candidate's uuid, filename, dimensions, size, and timestamp.

The output is intentionally conservative — we only emit groups where every
member satisfies the rule. Bigger savings are possible with looser rules
(see --gap-sec / --size-tolerance), but the defaults keep false-positives
near zero.

Usage:
  python3 scan.py \
      --library ~/Pictures/Photos\ Library.photoslibrary \
      --output  groups.json \
      --gap-sec 3 \
      --size-tolerance 0.10
"""

from __future__ import annotations
import argparse, json, sqlite3, sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Apple Cocoa epoch (2001-01-01 UTC) → Unix epoch offset (seconds)
APPLE_EPOCH_OFFSET = 978307200


@dataclass
class Photo:
    pk:        int      # Z_PK in ZASSET (stable across one scan)
    uuid:      str      # ZUUID (stable identifier shown elsewhere)
    filename:  str
    taken_at:  float    # Cocoa-epoch seconds
    width:     int
    height:    int
    size:      int      # ZORIGINALFILESIZE bytes
    uti:       str      # ZUNIFORMTYPEIDENTIFIER

    @property
    def taken_iso(self) -> str:
        ts = self.taken_at + APPLE_EPOCH_OFFSET
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def open_library(library: Path) -> sqlite3.Connection:
    db = library / "database" / "Photos.sqlite"
    if not db.exists():
        sys.exit(f"❌ No Photos.sqlite at {db}")
    # immutable=1 lets us read even while Photos.app holds a write lock
    return sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)


def iter_assets(conn: sqlite3.Connection):
    """Yield every non-trashed, non-hidden asset in chronological order."""
    cur = conn.cursor()
    cur.execute("""
        SELECT
            z.Z_PK,
            z.ZUUID,
            COALESCE(a.ZORIGINALFILENAME, z.ZFILENAME),
            z.ZDATECREATED,
            z.ZWIDTH,
            z.ZHEIGHT,
            COALESCE(a.ZORIGINALFILESIZE, 0),
            COALESCE(z.ZUNIFORMTYPEIDENTIFIER, '')
        FROM ZASSET z
        LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK
        WHERE z.ZTRASHEDSTATE = 0
          AND z.ZHIDDEN = 0
          AND z.ZDATECREATED IS NOT NULL
          AND z.ZDATECREATED > -3000000000   -- ignore epoch-zero junk
        ORDER BY z.ZDATECREATED
    """)
    for row in cur:
        yield Photo(*row)


def cluster(photos, gap_sec: float, size_tol: float):
    """
    Single-pass clustering: a photo joins the current cluster iff
        same (width, height)
        AND (taken_at - prev.taken_at) < gap_sec
        AND |size - prev.size| / prev.size < size_tol  (only if prev.size > 0)
    Otherwise it starts a new cluster. We yield clusters of size >= 2.
    """
    cluster: list[Photo] = []
    for p in photos:
        if cluster:
            prev = cluster[-1]
            gap  = p.taken_at - prev.taken_at
            size_ok = (
                prev.size == 0 or p.size == 0 or
                abs(p.size - prev.size) / prev.size < size_tol
            )
            if (gap < gap_sec
                    and p.width == prev.width
                    and p.height == prev.height
                    and size_ok):
                cluster.append(p)
                continue
            if len(cluster) >= 2:
                yield cluster
            cluster = [p]
        else:
            cluster = [p]
    if len(cluster) >= 2:
        yield cluster


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--library", type=Path,
                    default=Path.home() / "Pictures" / "Photos Library.photoslibrary",
                    help="Path to Photos Library.photoslibrary bundle")
    ap.add_argument("--output", type=Path, default=Path("groups.json"))
    ap.add_argument("--gap-sec", type=float, default=3.0,
                    help="Max seconds between consecutive shots to be in the same cluster")
    ap.add_argument("--size-tolerance", type=float, default=0.10,
                    help="Max relative difference in file size (0.10 = ±10%%)")
    args = ap.parse_args()

    conn   = open_library(args.library)
    photos = iter_assets(conn)
    groups = list(cluster(photos, args.gap_sec, args.size_tolerance))
    conn.close()

    photo_count = sum(len(g) for g in groups)
    savings     = photo_count - len(groups)
    payload = {
        "library":       str(args.library),
        "gap_sec":       args.gap_sec,
        "size_tolerance": args.size_tolerance,
        "stats": {
            "groups":          len(groups),
            "candidate_photos": photo_count,
            "deletable":       savings,
        },
        "groups": [
            {
                "size":   len(g),
                "span_sec": round(g[-1].taken_at - g[0].taken_at, 2),
                "photos": [asdict(p) | {"taken_iso": p.taken_iso} for p in g],
            }
            for g in groups
        ],
    }

    args.output.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    print(f"✅ Wrote {args.output}")
    print(f"   {len(groups):,} clusters, {photo_count:,} candidate photos")
    print(f"   keep 1 per cluster → delete {savings:,} ({savings/photo_count:.1%} of candidates)")


if __name__ == "__main__":
    main()
