#!/usr/bin/env python3
"""
snapsift / pick.py
===================

Given the groups.json from scan.py, decide *which* photo to keep in each
cluster and which ones to delete. Outputs plan.json and delete-uuids.txt.

Keeper heuristic (in order):
  1. Prefer original-format files (HEIC > JPG > PNG > MP4) — favors the
     iPhone-native capture over edited/shared/forwarded versions.
  2. Among same-UTI, keep the largest file size — proxy for "highest
     quality version" (more bits = less compression).
  3. If still tied, keep the earliest one (the original take).

This avoids needing pixel access to the photos themselves. We trust that
"bigger same-format file" usually means "original / less compressed",
which is exactly what you want as the survivor.

Usage:
    python3 pick.py --input groups.json --output plan.json \\
                    --uuid-out delete-uuids.txt
"""

from __future__ import annotations
import argparse, json, sys
from pathlib import Path
from collections import Counter


# Higher score = preferred to keep.
# This roughly maps "original iPhone capture" > "shared/converted version".
UTI_PRIORITY = {
    "public.heic":          100,
    "public.heif":          100,
    "public.jpeg":           80,
    "public.png":            60,
    "public.tiff":           50,
    "com.compuserve.gif":    20,
    "public.mpeg-4":         70,   # videos rank below same-quality stills
    "com.apple.quicktime-movie": 70,
}


def keeper(group: list[dict]) -> dict:
    """Pick the one photo from the cluster to keep."""
    def rank(p):
        uti_score = UTI_PRIORITY.get(p["uti"], 0)
        # primary: UTI priority, secondary: largest size, tertiary: earliest
        return (uti_score, p["size"], -p["taken_at"])
    return max(group, key=rank)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input",      type=Path, default=Path("groups.json"))
    ap.add_argument("--output",     type=Path, default=Path("plan.json"))
    ap.add_argument("--uuid-out",   type=Path, default=Path("delete-uuids.txt"),
                    help="Plain newline-delimited UUIDs to feed delete.applescript")
    ap.add_argument("--max-groups", type=int, default=None,
                    help="Only emit first N clusters (handy for cautious first-pass)")
    args = ap.parse_args()

    data = json.loads(args.input.read_text())

    plan_groups = []
    delete_uuids: list[str] = []
    kept_format = Counter()
    deleted_format = Counter()
    kept_bytes = 0
    deleted_bytes = 0

    groups = data["groups"][: args.max_groups] if args.max_groups else data["groups"]
    for g in groups:
        keep = keeper(g["photos"])
        deletes = [p for p in g["photos"] if p["uuid"] != keep["uuid"]]
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


if __name__ == "__main__":
    main()
