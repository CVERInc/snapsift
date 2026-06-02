#!/usr/bin/env python3
r"""
snapsift / scan.py
===================

Reads an Apple Photos library SQLite database and finds *near-duplicate*
groups that Photos.app's built-in Duplicates detector misses — specifically
"manual burst" sequences where someone held the shutter and got many
near-identical shots.

Strategy:
  1. Open Photos.sqlite read-only (immutable=1) so we don't disturb a
     running Photos.app.
  2. Walk every (non-trashed, non-hidden) asset in date order. Videos are
     skipped by default (--include-video to keep them).
  3. Group consecutive photos that share (width, height) AND were taken
     within --gap-sec of the previous one AND have file size within
     --size-tolerance AND keep the whole cluster inside --max-span seconds.
  4. Emit groups.json with one record per cluster, containing every
     candidate's uuid, filename, dimensions, size, timestamp, favorite
     flag, and Apple's own computed quality score.

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
from datetime import datetime, timezone
from pathlib import Path

# Apple Cocoa epoch (2001-01-01 UTC) → Unix epoch offset (seconds)
APPLE_EPOCH_OFFSET = 978307200

# Apple computes per-photo aesthetic scores (roughly 0..1) and stores them in
# ZCOMPUTEDASSETATTRIBUTES. We fold a handful into a single "quality" number so
# the keeper picker can prefer the genuinely better frame in a burst, not just
# the biggest file. Positive traits add, failure/noise subtract. The exact
# weights matter little — within one burst the scores move together and we only
# need a *relative* ordering. See quality_score().
QUALITY_POSITIVE = (
    "sharply_focused",
    "well_chosen",
    "well_framed",
    "well_timed",
    "interesting_subject",
    "pleasant_composition",
    "pleasant_lighting",
    "highlight_visibility",
)
QUALITY_NEGATIVE = ("failure", "noise")


def quality_score(components: dict) -> float:
    """Fold Apple's per-trait scores into one number; missing traits count 0."""
    pos = sum(components.get(k) or 0.0 for k in QUALITY_POSITIVE)
    neg = sum(components.get(k) or 0.0 for k in QUALITY_NEGATIVE)
    return round(pos - neg, 4)


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
    kind:      int      # ZKIND: 0 = image, 1 = video
    favorite:  bool     # ZFAVORITE — never deleted by pick.py
    quality:   float    # composite of Apple's computed aesthetic scores

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


def iter_assets(conn: sqlite3.Connection, include_video: bool = False):
    """Yield every non-trashed, non-hidden asset in chronological order."""
    cur = conn.cursor()
    kind_filter = "" if include_video else "AND z.ZKIND = 0"
    cur.execute(f"""
        SELECT
            z.Z_PK,
            z.ZUUID,
            COALESCE(a.ZORIGINALFILENAME, z.ZFILENAME),
            z.ZDATECREATED,
            z.ZWIDTH,
            z.ZHEIGHT,
            COALESCE(a.ZORIGINALFILESIZE, 0),
            COALESCE(z.ZUNIFORMTYPEIDENTIFIER, ''),
            z.ZKIND,
            z.ZFAVORITE,
            z.ZHIGHLIGHTVISIBILITYSCORE,
            c.ZSHARPLYFOCUSEDSUBJECTSCORE,
            c.ZWELLCHOSENSUBJECTSCORE,
            c.ZWELLFRAMEDSUBJECTSCORE,
            c.ZWELLTIMEDSHOTSCORE,
            c.ZINTERESTINGSUBJECTSCORE,
            c.ZPLEASANTCOMPOSITIONSCORE,
            c.ZPLEASANTLIGHTINGSCORE,
            c.ZFAILURESCORE,
            c.ZNOISESCORE
        FROM ZASSET z
        LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK
        LEFT JOIN ZCOMPUTEDASSETATTRIBUTES  c ON c.ZASSET = z.Z_PK
        WHERE z.ZTRASHEDSTATE = 0
          AND z.ZHIDDEN = 0
          {kind_filter}
          AND z.ZDATECREATED IS NOT NULL
          AND z.ZDATECREATED > -3000000000   -- ignore epoch-zero junk
        ORDER BY z.ZDATECREATED
    """)
    for row in cur:
        (pk, uuid, filename, taken_at, width, height, size, uti, kind,
         favorite, highlight, sharp, chosen, framed, timed, interesting,
         comp, light, failure, noise) = row
        quality = quality_score({
            "highlight_visibility":  highlight,
            "sharply_focused":       sharp,
            "well_chosen":           chosen,
            "well_framed":           framed,
            "well_timed":            timed,
            "interesting_subject":   interesting,
            "pleasant_composition":  comp,
            "pleasant_lighting":     light,
            "failure":               failure,
            "noise":                 noise,
        })
        yield Photo(pk, uuid, filename, taken_at, width, height, size, uti,
                    kind, bool(favorite), quality)


def cluster(photos, gap_sec: float, size_tol: float, max_span: float = 0.0):
    """
    Single-pass clustering: a photo joins the current cluster iff
        same (width, height)
        AND (taken_at - prev.taken_at) < gap_sec
        AND |size - prev.size| / prev.size < size_tol  (only if prev.size > 0)
        AND (max_span <= 0  OR  taken_at - cluster[0].taken_at <= max_span)
    Otherwise it starts a new cluster. We yield clusters of size >= 2.

    The gap is measured against the *previous* photo, so a slow drift could
    chain frames whose first and last are minutes apart — max_span caps that
    total span so a burst can't silently snowball into an unrelated session.
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
            span_ok = max_span <= 0 or (p.taken_at - cluster[0].taken_at) <= max_span
            if (gap < gap_sec
                    and p.width == prev.width
                    and p.height == prev.height
                    and size_ok
                    and span_ok):
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
    ap.add_argument("--max-span", type=float, default=30.0,
                    help="Max total seconds a cluster may span; 0 disables the cap")
    ap.add_argument("--include-video", action="store_true",
                    help="Also cluster videos (off by default — two short clips "
                         "shot back-to-back are rarely true duplicates)")
    args = ap.parse_args()

    conn   = open_library(args.library)
    photos = iter_assets(conn, include_video=args.include_video)
    groups = list(cluster(photos, args.gap_sec, args.size_tolerance, args.max_span))
    conn.close()

    photo_count = sum(len(g) for g in groups)
    savings     = photo_count - len(groups)
    payload = {
        "library":       str(args.library),
        "gap_sec":       args.gap_sec,
        "size_tolerance": args.size_tolerance,
        "max_span":      args.max_span,
        "include_video": args.include_video,
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
    if photo_count:
        print(f"   keep 1 per cluster → delete {savings:,} ({savings/photo_count:.1%} of candidates)")


if __name__ == "__main__":
    main()
