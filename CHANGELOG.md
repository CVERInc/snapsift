# Changelog

All notable changes to snapsift. Versions follow semantic versioning; 1.0.0 is
reserved for the first signed and notarized build.

## [Unreleased]

### Added
- **⇧K — "keep only this one."** In a group of five, one keystroke nominates the
  focused photo as the keeper and crosses out the rest, instead of pressing `X`
  four times (or `D` then `K`, which passes through a state where every photo is
  marked). `K` : `⇧K` is the same relationship as `X` : `⇧X` — the plain verb and
  the stronger one. Works in the grid and in the preview, and appears in the `?`
  cheat sheet in English, Japanese and Traditional Chinese.
  - It **marks only**: nothing leaves the library until the pre-commit sheet is
    confirmed. Pressing `⇧K` again on the same photo, before touching anything
    else in the group, puts the group back exactly as it was. (`A` keeps the
    whole group; plain `K` only un-marks the one photo it nominates.)
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
- **Snapsift's albums: it only takes out what it put in.** Snapsift now keeps a
  record of which photos it filed into each of its albums, and of the album
  itself (not just its name). A sort removes a photo from an album only if that
  record says Snapsift added it there. An album of your own that happens to
  share a name with one of Snapsift's, and any photo you dragged into a Snapsift
  album yourself, are left alone. Renaming a Snapsift album in Photos no longer
  makes Snapsift create a second one.
  - If you delete a kept photo in Photos, the copy Snapsift had filed under
    "Identical" as its duplicate leaves that album on the next sort — it is the
    only copy now. Nothing is deleted; it only leaves the album.
  - **Photos filed by earlier versions are not in the record, so they are never
    taken out automatically.** They stay in the album until you remove them
    yourself. The same goes for photos that were already in an album when
    Snapsift first found it. The first sort that meets such an album says so
    once, with the way out: delete the album (not the photos) and sort again.
  - If you open the library with an older build of Snapsift and it saves, the
    record is dropped: albums go back to add-only until the next sort files
    photos again.
- **A click on a photo no longer changes anything.** It moves the focus there.
  To keep or cross out with the mouse, use the two round buttons that appear on
  the focused photo, or right-click. Double-click opens the preview.

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
- An interrupted delete is no longer booked into the history while Photos access
  is missing or limited — "cannot see the photo" was being read as "the photo is
  gone". The check now waits until Photos access is full (it runs again as soon
  as access changes, not only at the next launch), and a delete started in the
  meantime adds to that pending record instead of replacing it.
- ⌘ / ⌃ / ⌥ combined with a letter, a digit or ⌫ can no longer trigger the plain
  key's action (⌘⌫ with nothing marked used to cross out the focused photo).
  This includes the arrow keys in the list and the grid: ⌘↑, ⌥→ and the like now
  do nothing there.
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
