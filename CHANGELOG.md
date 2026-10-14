# Changelog

All notable changes to snapsift. Versions follow semantic versioning; 1.0.0 is
reserved for the first signed and notarized build.

## [Unreleased]

### Release tooling
- `scripts/release.sh` chains build → the signing pipeline → appcast in one
  command, and a `publish` step copies the result to the hosting checkout.
  The feed/download host comes from one variable, `SNAPSIFT_BASE_URL`.
- The app bundle now carries `LICENSE.txt`, `Sparkle-LICENSE.txt` and
  `THIRD_PARTY_NOTICES.txt` in `Contents/Resources/` (the notices file is also
  at the repo root).

### Added
- **Album names in Apple Photos review.** Review tiles and the pre-commit
  review show user album names in English, Japanese and Taiwan Traditional
  Chinese, excluding snapsift's organizational albums. Names load only when
  a group or pre-commit review opens; ranking and marking are unchanged.
- **Folder Mode scanning, Trash removal and Put Back.** Choose multiple folders with saved
  access, compare duplicate and similar photos, and review grouped Live Photo,
  RAW + JPEG and sidecar files together. Cross-folder duplicates remain
  unmarked, and scan-only volumes show why removal is unavailable. Folder
  review is separate from Apple Photos scans, decisions and history, with
  English, Japanese and Taiwan Traditional Chinese interface text. Review
  counts, sizes, volumes and protected items before moving files to Trash.
  Folder history records original and Trash paths, recovers interrupted
  removals at launch, and offers Put Back without overwriting existing files.
  Partial moves, changed files and history failures are reported.
  Review tiles and the pre-commit sheet show distinct file-format labels,
  highlight RAW and grouped RAW companions, and flag mixed RAW/processed
  groups where an export may be worth keeping. Ranking and marking are unchanged.
- **⇧K — "keep only this one."** In a group of five, one keystroke nominates the
  focused photo as the keeper and crosses out the rest, instead of pressing `X`
  four times (or `D` then `K`, which passes through a state where every photo is
  marked). `K` : `⇧K` is the same relationship as `X` : `⇧X` — the plain verb and
  the stronger one. Works in the grid and in the preview, and appears in the `?`
  cheat sheet in English, Japanese and Traditional Chinese.
  - It **marks only**: nothing leaves the library until the pre-commit sheet is
    confirmed. Pressing `⇧K` again on the same photo, before touching anything
    else in the group, puts the group back exactly as it was. (`A` keeps the
    whole group; plain `K` only un-marks the one photo it nominates.) Holding
    `⇧K` down does not flip it back and forth. Works the same in Folder Mode.
  - Protected photos (favorite / edited / document) and anything snapsift could
    not classify are **never** crossed out by ⇧K — only the per-photo ⇧X path,
    which asks first, can cross out a known protection. The set it marks is the
    same `bulkRejectCandidates` rule `D` and the exact-duplicate pass already
    use; there is no second definition of "deletable".
  - It does not undo your decisions either: a protected photo you had already
    force-crossed-out yourself with ⇧X **stays** crossed out.
  - Marks ⇧K adds are attributed as "marked by you" in the audit log. A copy
    the exact-duplicate pass had already marked, and that stays marked, keeps
    its "Same photo" attribution.

### Changed
- Shared Core and PhotoKit libraries are now published from the root Swift
  package for macOS 14 and iOS 17. The macOS app and its tools continue to build
  from `app/`, consuming the same libraries locally.
- The shared PhotoKit library lets an app without a Photos sidecar review
  similar sets as groups: set photos get the same favorite, edited and document
  protection checks as group photos, and removal from sets goes through the same
  guarded deletion, journal and history. The macOS app's similar sets are unchanged.
- **Deleting from Apple Photos now stops if its recovery journal cannot be
  written.** Previously the deletion went ahead without the journal; now
  nothing is deleted and the usual "nothing was deleted" alert appears, so an
  interrupted deletion always leaves a record.
- **A click on a photo only focuses it, in both modes.** It used to make the
  clicked photo the keeper. Keep and cross-out are now two buttons on the
  focused (or hovered) card and items in its context menu, with "Keep only
  this one" there too; double-click opens the preview in Apple Photos Mode.
  They go through the same rules as K, X, ⇧X and ⇧K, so a protected photo
  still asks first and an unclassifiable one still cannot be marked.
- **VoiceOver can do the whole review.** A card is read as its position,
  capture date and what will happen to it, with the reason; an
  unclassifiable photo is read as protected, never as "no decision". Each card
  has named actions for the same verbs, and marks, keeper changes and banners
  are announced. The destructive buttons are spoken as their visible title
  plus the count, without the ⌘⏎ glyphs.
- **Sidebar dimming stays readable (proposal).** While the photos have focus,
  unselected sidebar rows dim to 0.85 instead of 0.35 and the selected row
  turns from filled to outlined. Increase Contrast turns dimming off; Reduce
  Motion turns the fades into cuts. Apple Photos Mode only.

### Fixed
- **Snapsift's albums now follow what the latest scan concluded about the photos
  it looked at.** Sorting used to only add: if you changed which copy to keep and
  sorted again, the old candidate stayed in "Exact Duplicates" next to the new
  one — the photo and its only other copy, in the album described as safe to
  remove. A sort now takes a photo out of a Snapsift album when this scan
  re-evaluated it and no longer puts it there, and the banner says how many.
  Photos the scan did not look at — results of an earlier scan of another album,
  or of another kind of scan — stay where they are; a Similar Sets scan takes
  nothing out. Membership only: nothing is deleted, and albums you made yourself
  are never touched.
- An interrupted Apple Photos delete is no longer booked into the history while
  Photos access is missing or limited — "cannot see the photo" was being read as
  "the photo is gone". The check now waits until Photos access is full (it runs
  again as soon as access changes, not only at the next launch), and a delete
  started in the meantime adds to that pending record instead of replacing it.
- ⌘ / ⌃ / ⌥ combined with a letter, a digit or ⌫ can no longer trigger the plain
  key's action (⌘⌫ with nothing marked used to cross out the focused photo).
  This includes the arrow keys in the list and the grid: ⌘↑, ⌥→ and the like now
  do nothing there. Folder Mode already ignored ⌘ and ⌃; it now ignores ⌥ too.
- `K` and `1–9` ignore a photo that is not in the group.
- `D` no longer leaves the "include protected" override switched on with no
  protected photo marked.

## [0.10.0] — 2026-09-18

The safety release. Everything below was reviewed in three adversarial rounds
and then dogfooded on a 120K-photo library.

### Protection
- Favorites, edited photos, documents and anything snapsift cannot classify are
  never deletion candidates. "Cannot classify" now means: collected into a
  **Please confirm** album for you to look at in Photos — never deletable here.
- Right before anything is deleted, the candidates **and every photo meant to
  survive** are re-fetched from the live library. A group whose survivors are
  gone is withdrawn and nothing in it is deleted.
- Deletion intent is journaled before the commit and reconciled on next launch.
- The Photos.sqlite sidecar is trusted only when it matches the library Photos
  is serving; otherwise the edited state is "unknown", and unknown is protected.
- Every synchronous PhotoKit metadata call goes through one lane with a timeout
  and a circuit breaker, so a hung Photos daemon cannot freeze the app or
  silently skip protection.
- CLI: `pick.py` refuses a `groups.json` without edited flags; `cli.py`
  propagates exit codes; `delete.applescript` re-reads favorites live.

### Interface
- Keyboard grammar: arrows move (← on the first photo returns to the sidebar,
  ↑/↓ move by row), Return opens the preview, **K** keeps the focused photo,
  X marks it, Esc always means "one level up, nothing changes".
- A visible focus ring on the focused photo; the inactive pane dims.
- Every DELETE mark says why; undecided photos no longer claim they will be
  deleted; one fact appears once per screen.
- Plain-language copy in English, Japanese and Traditional Chinese; the
  deletion history shows how many days are left to recover.

### Distribution
- Sparkle 2 auto-updates for the official binary (a source build never starts
  the updater and never contacts a server), hardened-runtime entitlements,
  ad-hoc signed local builds that verify.
- Decision logic lives in `SnapsiftCore/DeleteDecision` and is tested directly:
  214 → 337 checks, with negative controls.

## [0.9.1] and earlier

See the git history.
