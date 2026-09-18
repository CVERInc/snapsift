# snapsift

> **Sift the near-duplicate snaps Apple's built-in Duplicates detector misses** —
> specifically the "manual burst" sequences where someone held the shutter
> and got 10+ near-identical shots.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-black?logo=apple)](https://www.apple.com/macos/)

🌐 [日本語](https://cver.net/ja-jp/oss/snapsift) · [繁體中文](https://cver.net/zh-tw/oss/snapsift)

Built for a real Photos library of 120K+ photos where Apple's `Duplicates`
album was already empty, yet thousands of sub-second-apart shots remained.

There are two ways to use snapsift:

- **The macOS app** (`app/`) — a native SwiftUI window. Scan, review each
  cluster side-by-side, and delete the extras. Recommended for most people.
- **The Python tools** (repo root) — the original, hackable engine and CLI.
  Zero-dependency, reads the library directly. Great for scripting and tinkering.

## The macOS app

A native, on-device SwiftUI app built on Apple's own frameworks — nothing ever
leaves your Mac.

- **PhotoKit** for enumeration, thumbnails (fetched from iCloud on demand, so
  it works even with "Optimize Mac Storage"), and deletion straight into
  Recently Deleted (recoverable 30 days) — no AppleScript.
- **Apple quality ranking** — reads your library's own aesthetic scores so the
  keeper is the genuinely better frame, not just the biggest file.
- **Face-aware keeper** (Vision) — re-picks the frame where people's eyes are
  open and everyone's in shot.
- **Cross-time look-alikes** (Vision feature prints) — finds the same photo
  saved on different days, not just time bursts.
- **Surface, don't judge** — look-alike groups are sorted and presented; the
  app only ever pre-marks a photo for deletion when it is a **byte-verified
  exact duplicate** (identical original files). Everything else is yours to
  decide, and the built-in deletion history records which was which.
- **What "exact duplicate" compares, and what it doesn't.** Two copies can be
  byte-identical as *pixels* and still differ as *library entries*: one of them
  may be the copy you filed into albums or wrote a caption on. snapsift
  compares **album membership and captions/titles/descriptions** and leaves the
  copy carrying something extra unmarked (if it cannot read either signal, it
  treats the copy as carrying it). It does **not** compare **keywords, people,
  or places** — Photos exposes no public API for them, and a guard written from
  an unverified database schema would fail silently in the worst way, by making
  every exact-duplicate suggestion disappear. Deleting the wrong copy is
  recoverable for 30 days from Recently Deleted, keywords and all; this is a
  limit worth knowing, not a hole in the safety guarantee.
- **Protected photos are never pre-marked, and protection is re-checked
  against the live library right before anything is deleted.** Protected means
  favorites, edited photos, documents/scans — and anything snapsift could not
  determine (an unreadable edit state is treated as "edited", never as "not
  edited"). You can still force-delete a protected photo yourself; nothing else
  can. Videos are off by default.

Build it (no Xcode needed):

```bash
cd app
./scripts/build-app.sh          # → ~/Applications/snapsift.app, then double-click
swift run SnapsiftTests         # run the Core test suite
```

First-launch notes:

- **Gatekeeper**: the app is unsigned for distribution purposes (built from
  source on your machine, so macOS usually launches it directly; a downloaded
  copy needs right-click → Open the first time). The build script does ad-hoc
  sign the bundle, which carries no identity but is what lets the executable
  launch at all on Apple Silicon after its embedded-framework path is patched;
  the script verifies that with `codesign --verify --deep --strict` and refuses
  to finish if it fails.
- **Photos access**: on first scan, macOS asks for read/write access to your
  Photos library — required to enumerate, sort into albums, and delete into
  Recently Deleted.
- **Full Disk Access** (optional): lets snapsift read Apple's own quality
  scores, real file sizes and the edited flag from `Photos.sqlite` (read-only).
  Without it everything still works: keeper ranking loses the quality signal,
  no reclaimable-space estimate is shown, and the edited flag is read one photo
  at a time through PhotoKit instead. Any photo whose edit state cannot be
  established that way is **protected** and a banner says how many — snapsift
  never assumes "not edited". The status bar will tell you when the estimate is
  missing, and it also tells you if it cannot confirm which Photos library this
  Mac is using (a copied library left in `~/Pictures` reads plausibly and
  answers everything months out of date, so snapsift refuses to trust it).

## How it works (the engine)

Five small tools. The core (scan/pick/delete) has **zero dependencies** beyond
Python 3 and macOS; the two optional passes use Pillow.

| Step | Tool | What it does |
|---|---|---|
| 1 | `scan.py` | Reads `Photos.sqlite` directly (read-only, immutable). Walks every non-trashed **photo** (videos skipped by default) in date order and clusters them by `(width, height)` + sub-3s time gap + ±10% file size, capped at a 30s total span. Carries each frame's favorite flag and Apple's own quality scores. Emits `groups.json`. |
| 2 | `pick.py` | For each cluster, picks one keeper: **favorites and edited photos are never deleted**, then Apple's quality score, then UTI priority (HEIC > JPG > PNG), then larger file. **Refuses to run** on a `groups.json` that predates the `edited` flag (re-run `scan.py`, or accept favorites-only protection with `--allow-legacy-groups`). Emits `plan.json` and `delete-uuids.txt`. |
| 3 | `delete.applescript` | Reads `delete-uuids.txt` and tells `Photos.app` to delete the marked items in batches of 100. Re-reads each item's **favorite** flag from the live library first and skips favorites. They go to "Recently Deleted" → recoverable for 30 days. |
| L3 | `hash.py` *(opt.)* | **Cross-time** near-duplicates: dHashes each photo's thumbnail and groups the matches via a BK-tree, so the same shot saved on different days collapses together. Emits a `groups.json`-shaped file that feeds straight back into `pick.py`. Needs `pip install "Pillow>=9"`. |
| UI | `review.py` *(opt.)* | A local web page to eyeball every cluster before deleting: keeper highlighted, click to re-pick, ★ favorites locked, then **Export** the reviewed delete list. Reads any `groups.json` (burst *or* perceptual). stdlib server; Pillow only sharpens the thumbnails. |

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

**This section is about the CLI pipeline** (`scan.py` → `pick.py` →
`delete.applescript`). The macOS app enforces more than the CLI can — where
they differ it is said so below.

- `Photos.sqlite` is opened with `?mode=ro&immutable=1`, so we never touch
  Apple's data file even while Photos.app is running.
- **Favorites are never deleted.** A favorited frame always survives — and
  if a whole cluster is favorited, nothing in it is deleted. This one is
  re-checked LIVE: `delete.applescript` re-reads every item's `favorite`
  property from Photos immediately before deleting it, so favoriting a photo
  after the scan protects it too.
- **Edited photos are never deleted — as of the scan.** `scan.py` records each
  photo's adjustment state and `pick.py` never puts an edited photo in the
  delete list. The limit, stated plainly: Photos' AppleScript dictionary
  exposes no edited/adjustment property, so `delete.applescript` **cannot**
  re-check it. A photo edited AFTER the scan that produced `delete-uuids.txt`
  will still be moved to Recently Deleted (recoverable 30 days). Re-run
  `scan.py` and `pick.py` if the library has been worked on since. **The macOS
  app does not have this gap** — it re-reads the edited flag from the live
  library right before it deletes anything, and holds back anything it cannot
  read.
- **A `groups.json` without `edited` flags is refused**, not quietly downgraded:
  `pick.py` exits non-zero and tells you to re-run `scan.py`. `--allow-legacy-groups`
  opts in to favorites-only protection and says so loudly, twice.
- **Unclassifiable photos are never deleted — macOS app only.** When the app
  cannot determine whether a frame is edited (no Full Disk Access, or the
  library the quality sidecar reads couldn't be confirmed as the one Photos is
  actually using), or a document-eval ran on an image that wasn't on-device
  (iCloud-evicted), that frame is **never a delete candidate** — not
  auto-suggested, not markable by hand, and not admissible even through the
  "include protected" override, because there is no fact to consent to
  overriding. Ruling (chodaict, 2026-09-16): these photos are collected into a
  Photos album — **"Snapsift · Needs a look"** — non-destructively (membership
  only; no photo is deleted, and no album you made is ever touched), so a human
  decides in Photos.app instead of the tool guessing. The same album also
  collects videos whose Live Photo pairing could not be confirmed. A frame can
  never sit in both "Needs a look" and "Exact Duplicates": whichever the latest
  sort decides, the frame is taken out of the other one, so Photos.app never
  shows you the same photo labelled both "safe to remove" and "snapsift
  couldn't read this". This is stricter than "not
  pre-marked": it replaces that earlier compromise.
- **Documents/scans** are only protected for input produced by the macOS app —
  `scan.py` cannot detect them (no pixel access). The CLI path does not protect
  documents.
- **Videos are skipped by default** (two short clips shot back-to-back are
  rarely true duplicates). Opt in with `scan.py --include-video`.
- **Runaway clusters are capped** by `--max-span` (default 30s) so a slow
  drift of near-identical frames can't silently chain across an unrelated
  session.
- Deletion goes via Photos' own AppleScript bridge, so items land in
  "Recently Deleted" — fully recoverable for 30 days.
- iCloud sync handles the rest: deleting on the Mac also clears the
  duplicates from iCloud and from every other device.
- Run on a small `--max-groups 10` plan first to validate.

## Usage

Each tool is a standalone script (`python3 scan.py …`). If you `pip install .`,
the same five tools are also reachable through one console command — handy for
discovery and scripting:

```bash
snapsift --help            # lists: scan · pick · delete · hash · review
snapsift scan   --gap-sec 5    # == python3 scan.py   --gap-sec 5
snapsift pick   --max-groups 10
snapsift delete delete-uuids.txt
```

The per-script form below works identically — pick whichever you prefer.

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

### Optional: review visually before deleting

```bash
python3 review.py --groups groups.json     # opens http://127.0.0.1:8765
# click to re-pick keepers, then "Export" → writes delete-uuids.txt
```

### Optional: L3 cross-time perceptual pass

```bash
pip install "Pillow>=9"
python3 hash.py --output hash-groups.json --max-distance 2
python3 review.py --groups hash-groups.json --uuid-out hash-delete-uuids.txt
osascript delete.applescript "$(pwd)/hash-delete-uuids.txt"
```

## Development

```bash
pip install pytest "Pillow>=9"
pytest                 # pure-logic tests — no Photos library needed
```

The clustering, keeper, hashing and grouping logic are all pure functions with
unit tests; only the thin SQLite/thumbnail IO layer touches a real library.

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

- [x] L3: perceptual hashes over `derivatives/` thumbnails to catch
  near-duplicates *across* time (different days, same photo) — `hash.py`.
- [x] Web review UI: clusters side-by-side, override the picker's choice —
  `review.py`.
- [x] Smarter keeper: weighted by `ZCOMPUTEDASSETATTRIBUTES` sharpness /
  framing / timing scores Apple already computes — `pick.py`.
- [x] Package as a single `snapsift` console entry point — `cli.py`.
- [x] Face-aware keeper: prefer the frame where everyone's eyes are open.

## License

MIT.
