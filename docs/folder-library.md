# Shared Folder sessions

The root `SnapsiftFolder` product owns Folder scan, review, removal and history orchestration on iOS 17 and macOS 14. It also exports the former `SnapsiftAppSupport` review state and formatting helpers, with the same names. App shells own folder picking, observation, localization and confirmation UI. There are no third-party dependencies.

## Folders and scan

Create a `FolderLibrarySession` on the main actor with `FolderBookmarkStore(url:)` and `FolderHistoryStore(historyURL:intentURL:)` at locations owned by the calling app. The session requires both stores; different apps must supply separate locations. macOS supplies its existing defaults, preserving `folders.json`, `history.json` and `pending-removal.json`.

Call `loadFolders()`, then pass document-picker or folder-panel URLs to `addFolders(_:)`. `removeFolder(_:)` removes a bookmark and discards the current review. Read `folders` for resolved URLs, stale-bookmark and unavailable status.

`startScan()` resolves bookmarked access, runs `FolderScanPipeline.scan`, probes metadata and installs `FolderReviewState`. `cancelScan()` never installs a cancelled result, including a decoder or metadata probe that finishes late. Bookmark accesses stop when scanning finishes; result accesses remain held during review and stop on `discardResult()`. Discard clears all scan decisions, badges and focus. No Folder scan snapshot is persisted.

`onChange` fires before observable state changes. The shell can forward it to its observation mechanism. `onMessageChange` supplies typed message changes before assignment, allowing a shell to retain the language used when each outcome arrived. `isScanning`, `hasScanned`, `notice` and `errorOutcome` report scan state and typed finished/cancelled/failed outcomes. Optional scan, metadata, volume, bookmark-resolution and access ports support bounded tests without real image decoding or system Trash effects; defaults preserve the production pipeline.

## Review and removal

Read `groups`, `item(for:)`, `uniqueMetadataIDs`, `crossFolderItemIDs` and `crossFolderMatches`. Review decisions go through `promote`, `keepOnly`, `keepAll`, `toggleDeleteAll`, `toggleReject`, `forceReject` and `setIncludeProtected`. Protected overrides still require informed app confirmation; unverifiable items cannot be force-included.

Call `presentRemovalReview()` to lock the operation and obtain `removalReview`, including `committer.preCommitSummary` volume facts, eligibility and withdrawals. `cancelRemovalReview()` releases that lock. After confirmation, `commitReviewed(_:) async -> FolderCommitOutcome?` accepts only the current review and returns the actual removed count plus ordered problems. A stale/consumed review returns nil.

Problems carry group withdrawals and paths, per-item failures, stale/protection/burst/unverified/keeper/survivor counts, audit failure, commit failure and pending-intent/history-read failure. Successful IDs leave review; failed protected items retain their marks and consent. Focus and cross-folder badges are repaired. `activity` guards review, commit, reconciliation and Put Back; `operationReport` supplies structured report sections for localization.

## History and recovery

`presentHistory()` and `refreshHistory()` reconcile intent, balance bookmark accesses and reload `historyEntries`. `putBack(_:)` uses the injected Trash move port, yields once for busy UI, preserves conflict/parent/rollback/persistence outcomes and reloads history. `historyReadError` distinguishes a failed read from empty history.

Call `reconcileAtLaunch() -> FolderReconciliationOutcome?` once from the outer app surface. It runs independently of Photos authorization, reports recovered and unavailable counts or a reconciliation error, and returns nil when already attempted or busy. History refresh can retry a failed reconciliation. Intent alone never establishes a removal.

The system Trash port still throws `FolderHistoryError.trashUnavailable` on iOS. The library never substitutes permanent deletion. iOS Finder tag/comment facts remain unknown; this extraction does not change metadata, volume, grouped-file, commit-time re-check, journal or restore semantics. The macOS facade retains `NSOpenPanel`, SwiftUI/NSImage thumbnails and the existing localized messages.
