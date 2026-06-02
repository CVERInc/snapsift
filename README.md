# snapsift

> Sift the near-duplicate snaps Apple's built-in Duplicates detector misses
> — specifically the "manual burst" sequences where someone held the shutter
> and got 10+ near-identical shots.

Built for a real Photos library of 120K+ photos where Apple's `Duplicates`
album was already empty, yet thousands of sub-second-apart shots remained.

## How it works

Three small tools, no dependencies beyond Python 3 and macOS:

| Step | Tool | What it does |
|---|---|---|
| 1 | `scan.py` | Reads `Photos.sqlite` directly (read-only, immutable). Walks every non-trashed asset in date order and clusters them by `(width, height)` + sub-3s time gap + ±10% file size. Emits `groups.json`. |
| 2 | `pick.py` | For each cluster, picks one keeper using a UTI-priority + filesize heuristic (HEIC > JPG > PNG; larger file = more bits = less compression). Emits `plan.json` and `delete-uuids.txt`. |
| 3 | `delete.applescript` | Reads `delete-uuids.txt` and tells `Photos.app` to delete the marked items in batches of 100. They go to "Recently Deleted" → recoverable for 30 days. |

## Why it works

Apple's Duplicates feature is conservative: it only flags photos with very
similar perceptual hashes *and* matching metadata. Manual sequences ("I held
the shutter for two seconds and got 15 frames") are intentional captures
from Apple's point of view, so the algorithm leaves them all.

But for users, those 15 frames *are* duplicates — the user just wants the
best one. We detect them by relying on the only signal that's both fast and
nearly perfect: **photos taken within seconds of each other, same camera,
same dimensions, similar file size, are nearly always near-duplicates.**

Real-world hit rate on a 120K-photo library:

- `--gap-sec 3 --size-tolerance 0.10` (default): **4,142 clusters,
  6,608 deletable, ≈19 GB recovered.** Near-zero false positives in spot
  checks.
- `--gap-sec 5`: more aggressive, ~38K candidates.
- `--gap-sec 10`: aggressive, ~46K candidates — some misses (people
  legitimately took multiple shots at an event).

## Safety

- `Photos.sqlite` is opened with `?mode=ro&immutable=1`, so we never touch
  Apple's data file even while Photos.app is running.
- Deletion goes via Photos' own AppleScript bridge, so items land in
  "Recently Deleted" — fully recoverable for 30 days.
- iCloud sync handles the rest: deleting on the Mac also clears the
  duplicates from iCloud and from every other device.
- Run on a small `--max-groups 10` plan first to validate.

## Usage

```bash
# 1. Scan
python3 scan.py \
    --library ~/Pictures/Photos\ Library.photoslibrary \
    --output groups.json

# 2. Plan — start with 10 groups to validate
python3 pick.py --input groups.json --output plan.json \
    --uuid-out delete-uuids.txt --max-groups 10

# 3. Open Photos.app, then delete
osascript delete.applescript "$(pwd)/delete-uuids.txt"

# Validate: open Photos.app → "Recently Deleted" → confirm
# Then re-run without --max-groups and apply.
```

## Schema gotchas (for hackers)

- `ZASSET.ZDATECREATED` is Cocoa epoch (seconds since 2001-01-01 UTC). Add
  978307200 to get Unix epoch.
- `ZASSET.ZAVALANCHEUUID` flags iOS-native burst groups — but on the
  test library this only accounts for 121 groups / 1,141 photos, ~10× less
  than what time-clustering finds.
- `ZADDITIONALASSETATTRIBUTES.ZORIGINALSTABLEHASH` is Apple's own content
  hash. Exact matches are rare (the test library had 130) because most
  "duplicates" are *visually* identical but byte-different.
- Apple already tracks `ZDUPLICATEMETADATAMATCHINGALBUM` and
  `ZDUPLICATEPERCEPTUALMATCHINGALBUM`. They're cleared after the user
  resolves Duplicates; check before relying on them.

## Roadmap

- [ ] L3: compute perceptual hashes on `derivatives/` thumbnails to
  catch near-duplicates *across* time (different days, same photo).
- [ ] Web review UI: show each cluster side-by-side, let the user override
  the picker's choice.
- [ ] Smarter keeper picker: weight by `ZCOMPUTEDASSETATTRIBUTES`'s sharpness
  / face score fields Apple already computes.

## License

MIT.
