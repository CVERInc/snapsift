#!/usr/bin/env python3
"""
snapsift / pick.py
===================

Given the groups.json from scan.py, decide *which* photo to keep in each
cluster and which ones to delete. Outputs plan.json and delete-uuids.txt.

A frame is PROTECTED — never deleted — if it is a favorite OR an edited frame
(the user applied adjustments) OR a document/scan. A cluster of all-protected
frames deletes nothing. Over-protecting is the safe direction: the #1 rule is to
never mark a frame a human likely wants to keep.

Keeper heuristic (in order, highest first):
  1. Never delete a protected frame (favorite / edited / document). Among the
     rest, a favorite always wins the keeper slot.
  2. Prefer Apple's own per-photo quality score (sharpness, framing,
     timing, low noise…) — the genuinely better frame, not just the biggest
     file. Scores are quantised before comparison so near-ties fall through
     to the tiebreakers rather than splitting hairs on noise.
  3. Prefer the frame with genuine original-camera metadata (intact EXIF
     Make/Model) over an EXIF-stripped social-app re-save. Sits above
     sharpness/format/size: newer or larger does NOT mean better.
  4. Prefer the sharper frame (quantised like quality). A WITHIN-GROUP tiebreak
     only — it reorders the keeper inside a real multi-frame group and can never
     on its own add a frame to the delete set. Blur is never a delete trigger.
  5. Prefer original-format files (HEIC > JPG > PNG > MP4) — favors the
     iPhone-native capture over shared/forwarded versions.
  6. Among same-UTI, keep the largest file size — proxy for "highest
     quality version" (more bits = less compression).
  7. If still tied, keep the earliest one (the original take).

`pick.py` REFUSES to run on a groups.json without `edited` flags (older
scan.py output) rather than silently degrading to favorites-only protection —
pass --allow-legacy-groups to accept that degradation explicitly.

We never need pixel access here. scan.py provides `favorite`, `edited` and the
aesthetic score straight from Photos.sqlite; `is_document`, `sharpness` and
`original_camera` are Vision/pixel-derived and only present when the input
came from the macOS app — when absent they are treated as unknown-falsy, so
document protection is only in effect for app-produced input. Anything not the
keeper *and* not protected gets deleted.

Usage:
    python3 pick.py --input groups.json --output plan.json \\
                    --uuid-out delete-uuids.txt
"""

from __future__ import annotations
import argparse, json, math, sys
from pathlib import Path
from collections import Counter


# Higher score = preferred to keep.
# This roughly maps "original iPhone capture" > "shared/converted version".
# RAW formats rank at 90 — above JPEG (80) but below HEIC (100).  A RAW file
# is always the highest-fidelity capture; it is never a re-compressed derivative.
# HEIC beats RAW only because HEIC is the iPhone-native processed result.
# Must be kept in sync with SnapsiftCore/Keeper.swift `utiPriority`.
UTI_PRIORITY = {
    "public.heic":               100,
    "public.heif":               100,
    # RAW formats — above JPEG, below HEIC
    "com.adobe.raw-image":        90,   # DNG (Adobe / Apple canonical)
    "public.camera-raw-image":    90,   # generic RAW abstract base type
    "com.canon.cr2-raw-image":    90,   # Canon CR2
    "com.canon.cr3-raw-image":    90,   # Canon CR3
    "com.nikon.raw-image":        90,   # Nikon NEF
    "com.nikon.nrw-raw-image":    90,   # Nikon NRW (compact Nikon RAW)
    "com.sony.arw-raw-image":     90,   # Sony ARW
    "com.fuji.raf-raw-image":     90,   # Fujifilm RAF
    "com.panasonic.rw2-raw-image": 90,  # Panasonic RW2
    "com.dng":                    90,   # alternative DNG UTI seen on some imports
    "public.jpeg":                80,
    "public.png":                 60,
    "public.tiff":                50,
    "com.compuserve.gif":         20,
    "public.mpeg-4":              70,   # videos rank below same-quality stills
    "com.apple.quicktime-movie":  70,
}


def quality_bucket(quality: float) -> int:
    """Quantise a quality score to integer tenths with deterministic, platform-
    independent round-half-up. This is the SAME rule the Swift app uses
    (`Keeper.rankKey`): a pure IEEE-754 `floor(q*10 + 0.5)`, NOT Python's
    banker's `round(q, 1)` — so the CLI and the app always pick the same keeper.
    Quantising means noise-level quality differences fall through to the
    format/size tiebreakers instead of splitting hairs."""
    return math.floor((quality or 0.0) * 10 + 0.5)


def rank(p: dict) -> tuple:
    """Sort key for 'most worth keeping' — higher is better. Mirrors the Swift
    `Keeper.rankKey` EXACTLY so the CLI and the app never disagree on the keeper.

    Order, highest first: favorite, Apple quality (quantised), original-camera,
    sharpness (quantised), UTI priority, file size, earliest take.

    original_camera sits above sharpness/format/size: a genuine camera capture
    beats an EXIF-stripped re-save even if the re-save is newer/larger. sharpness
    sits BELOW quality (so it can't override the real quality signal) and is a
    within-group tiebreak ONLY — it never expands the delete set (see `deletes`,
    which keys off protection, not blur).
    """
    return (
        1 if p.get("favorite") else 0,
        quality_bucket(p.get("quality") or 0.0),
        1 if p.get("original_camera") else 0,
        quality_bucket(p.get("sharpness") or 0.0),
        UTI_PRIORITY.get(p["uti"], 0),
        p["size"],
        -p["taken_at"],
    )


def is_protected(p: dict) -> bool:
    """A frame a human likely wants to keep regardless of keeper choice: a
    favorite, an edited frame, or a document/scan. Protected frames are NEVER
    deleted. Mirrors Swift `Photo.isProtected`. Over-protection is the safe
    direction — the #1 rule is to never mark a frame a human likely wants."""
    return bool(p.get("favorite") or p.get("edited") or p.get("is_document"))


def keeper(group: list[dict]) -> dict:
    """Pick the one photo from the cluster to keep."""
    return max(group, key=rank)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input",      type=Path, default=Path("groups.json"))
    ap.add_argument("--output",     type=Path, default=Path("plan.json"))
    ap.add_argument("--uuid-out",   type=Path, default=Path("delete-uuids.txt"),
                    help="Plain newline-delimited UUIDs to feed delete.applescript")
    ap.add_argument("--max-groups", type=int, default=None,
                    help="Only emit first N clusters (handy for cautious first-pass)")
    ap.add_argument("--allow-legacy-groups", action="store_true",
                    help="Proceed on a groups.json that carries no 'edited' flags. "
                         "Protection then degrades to FAVORITES ONLY: an edited "
                         "photo can be written to delete-uuids.txt. Re-running "
                         "scan.py is almost always the right answer instead.")
    args = ap.parse_args()

    data = json.loads(args.input.read_text())

    # FAIL CLOSED on a groups.json with no `edited` flags.
    #
    # A groups.json written by an older scan.py carries no `edited` key, and
    # `is_protected` then reads a missing key as False — so every edited photo
    # in it lands in delete-uuids.txt and delete.applescript moves it to
    # Recently Deleted. The five-step pipeline in the README explicitly invites
    # running the steps on different days, so a months-old groups.json is a
    # NORMAL input, not an exotic one.
    #
    # This used to be one line on stderr, scrolling past above two ✅ lines.
    # A warning that has to be noticed to protect anything protects nothing:
    # the guarantee ("an edited frame is never deleted") is either enforced or
    # it isn't. Missing data ⇒ refuse, and let the user opt in explicitly if
    # they really mean favorites-only.
    #
    # Checked across EVERY photo, not a single sample: a hand-merged or
    # concatenated groups.json can carry the flag in its first clusters and not
    # in its last, which is precisely the file a first-photo check waves through.
    missing = sum(1 for g in data["groups"] for p in g["photos"] if "edited" not in p)
    if missing:
        if not args.allow_legacy_groups:
            print(f"❌ {args.input}: {missing:,} photos carry no 'edited' flag "
                  "(written by an older scan.py?).\n"
                  "   Refusing to write a delete list: without that flag an edited "
                  "photo would be treated as unprotected and deleted.\n"
                  "   Fix: re-run scan.py to regenerate groups.json.\n"
                  "   Or, if you accept FAVORITES-ONLY protection, re-run with "
                  "--allow-legacy-groups.", file=sys.stderr)
            return 2
        print("=" * 72, file=sys.stderr)
        print("⚠️  --allow-legacy-groups: PROTECTION IS DEGRADED TO FAVORITES ONLY.",
              file=sys.stderr)
        print(f"   {missing:,} photos in {args.input} carry no 'edited' flag, so an "
              "edited photo\n   CAN be written to the delete list. Documents are not "
              "protected either\n   (that flag only exists in app-produced input).",
              file=sys.stderr)
        print("=" * 72, file=sys.stderr)

    plan_groups = []
    delete_uuids: list[str] = []
    kept_format = Counter()
    deleted_format = Counter()
    kept_bytes = 0
    deleted_bytes = 0

    groups = data["groups"][: args.max_groups] if args.max_groups else data["groups"]
    for g in groups:
        keep = keeper(g["photos"])
        # Delete everything that is neither the keeper nor protected. Protected
        # frames (favorite / edited / document) are sacred — a cluster of all
        # protected frames deletes nothing.
        deletes = [p for p in g["photos"]
                   if p["uuid"] != keep["uuid"] and not is_protected(p)]
        plan_groups.append({
            "size":     g["size"],
            "span_sec": g["span_sec"],
            "keep":     keep,
            "delete":   deletes,
        })
        kept_format[keep["uti"] or "(none)"] += 1
        kept_bytes += keep["size"]
        for d in deletes:
            delete_uuids.append(d["uuid"])
            deleted_format[d["uti"] or "(none)"] += 1
            deleted_bytes += d["size"]

    plan = {
        "source":  str(args.input),
        "stats": {
            "groups":         len(plan_groups),
            "kept":           len(plan_groups),
            "deleted":        len(delete_uuids),
            "kept_bytes":     kept_bytes,
            "deleted_bytes":  deleted_bytes,
            "kept_formats":   dict(kept_format),
            "deleted_formats": dict(deleted_format),
        },
        "groups": plan_groups,
    }
    args.output.write_text(json.dumps(plan, indent=2, ensure_ascii=False))
    args.uuid_out.write_text("\n".join(delete_uuids) + "\n")

    print(f"✅ {args.output} — {len(plan_groups):,} groups")
    print(f"✅ {args.uuid_out} — {len(delete_uuids):,} UUIDs to delete")
    print()
    print(f"Kept   : {len(plan_groups):,} photos, {kept_bytes/1e9:.2f} GB")
    print(f"Delete : {len(delete_uuids):,} photos, {deleted_bytes/1e9:.2f} GB")
    print()
    print(f"Keep format mix:")
    for fmt, n in kept_format.most_common():
        print(f"  {fmt:30s} {n:>6,}")
    print(f"Delete format mix:")
    for fmt, n in deleted_format.most_common():
        print(f"  {fmt:30s} {n:>6,}")
    if missing:
        # Last word, not first: the reader has to scroll past the delete count
        # to leave, so the caveat sits where they actually end up.
        print()
        print(f"⚠️  favorites-only protection was in force for this plan "
              f"({missing:,} photos had no 'edited' flag).", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
