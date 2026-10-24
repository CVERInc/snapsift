# Shared Apple Photos sessions

The root `SnapsiftPhotoKit` product owns Apple Photos scan, review, persistence and deletion orchestration on iOS 17 and macOS 14. App shells own authorization, observation, localization and confirmation UI. It has no third-party dependencies.

## Scan

Create a `PhotoLibrarySession` on the main actor with `PhotoLibraryStorage(directory:)` and `PhotoLibraryAlbumTitles`. The directory must belong to the calling app. Individual snapshot, journal and history URLs can also be supplied to `PhotoLibraryStorage(snapshotURL:journalURL:historyURL:)`.

After obtaining Photos read/write authorization, call `loadAlbums()`, select `scanSource` (`.wholeLibrary` or `.album(AlbumItem)`), set `includeVideo`, and call `startScan(.burst)`, `startScan(.lookAlikes)` or `startScan(.similarSets)`. `cancelScan()` restores the previous persisted session. A missing scoped album leaves the previous review untouched.

`onChange` fires before observable state changes; the shell can forward it to its observation mechanism. Read `progress`, `progressFraction` and `scanNotice` to present localized progress and outcomes. `configure(albumTitles:namingLanguage:fallbackSetName:)` supplies localized output without changing the algorithms.

## Review and final review

Read `groups`, `exactDupeGroupIDs`, `categories`, protection counts and `uniqueMetadataIDs`. Review decisions go through `promote`, `keepOnly`, `keepAll`, `toggleKeepAll`, `rejectAll`, `toggleDeleteAll`, `toggleReject`, `forceReject` and `setIncludeProtected`. The last two require the shell's prior informed confirmation. Unverifiable frames cannot be force-included.

`refineWithFaces()` re-picks keepers without widening deletion eligibility. `asset(for:)` and `imageManager` vend images for the shell. `loadReviewDetails(for:)` and `reviewAlbumNames(for:)` provide user-album metadata. `withdrawnGroupIDs()` supplies final-review withdrawal reasons; the commit repeats the live checks.

Call `restoreSnapshot()` on launch and `flushSnapshotSync()` when terminating. Decision changes schedule ordered, debounced saves automatically. A stale library token drops app-seeded marks and exact badges while retaining user decisions under the existing protection rules. Protected overrides are never persisted. `staleRestoreClearedCount`, `vanishedMarkCount`, `snapshotSaveFailedNotice` and `snapshotUnreadableNotice` let the shell present loss/degradation notices.

`writeAlbums()` performs membership-only organization using the supplied current, localized and retired titles. `writeAlbumsReport()` returns an outcome for each app-owned album and captures per-album failures; retrying reruns the whole pass, with membership additions remaining idempotent. `rotate(frameID:clockwise:)` affects display only; after user confirmation, `saveRotationToPhotos(frameID:)` live-checks pristine edit state and writes a reversible Photos adjustment. Unknown or already-edited state refuses the write.

## Commit and history

After the shell's final confirmation, call `deleteReviewed(...)`. It always uses `CommitOrchestrator` and `PhotoKitCommitPorts`, including live favorite/edit checks, burst siblings, survivor validation, the pre-delete intent journal and post-delete audit. Callbacks report stale, protected, burst, undetermined and survivor withdrawals. The result is the actual deletion count; `lastDeleteAuditFailed` reports a committed deletion whose audit could not be written.

Call `reconcileDeletionJournal()` after authorization at launch. Interrupted intent is reconciled against live assets and existing history; intent alone never establishes a deletion. Read `session.history.loadSessions()` and `session.history.exportText(labels:)` for history and export. `PhotoKitCommitPorts.make(storage:editedNow:)` also accepts explicit storage when consumed independently of the session.

## Optional macOS enrichment

`PhotoLibraryEnrichmentPort` supplies quality/size/edit facts, verified library identity, metadata and optional set naming. The macOS app's `MacPhotoLibraryEnrichment` implements it with the existing `QualitySidecar` and `Apfel`; those implementations remain in the macOS app. The public library never opens Photos.sqlite or uses private metadata keys.

With no port, the session uses public PhotoKit resource metadata and timed per-asset edited-state reads. Unreadable edit state remains protected, quality contributes no signal, and unreadable size remains zero/unknown. Unavailable caption facts withhold exact-duplicate suggestions, matching macOS without Full Disk Access. On iOS 27 / macOS 27 built with the Xcode 27 SDK (`#if compiler(>=6.4)`), pass `PhotoLibrarySession(… descriptionSource: photoKitCaptionDescriptions(for:))` to read Photos captions instead: a non-empty caption makes a copy described, and a copy without one stays undetermined because PhotoKit exposes no title. Without a source, unavailable caption facts withhold exact-duplicate suggestions as before.

The macOS shell supplies its existing `DeletionAuditLog.directory`, preserving `last-scan.json` schema 1, `pending-delete.json` and `deletions.jsonl` at their existing locations. Other apps supply their own locations and never share runtime data.
