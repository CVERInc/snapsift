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
    confirmed, and `K` or `A` afterwards undo it the ordinary way.
  - Protected photos (favorite / edited / document) and anything snapsift could
    not classify are **never** crossed out by ⇧K — only the per-photo ⇧X path,
    which asks first, can cross out a known protection. The set it marks is the
    same `bulkRejectCandidates` rule `D` and the exact-duplicate pass already
    use; there is no second definition of "deletable".
  - It does not undo your decisions either: a protected photo you had already
    force-crossed-out yourself with ⇧X **stays** crossed out.
  - Marks made this way are attributed as "marked by you" in the audit log,
    never as an app suggestion.

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
