import Foundation
import Photos
import SnapsiftCore

/// One reviewable near-duplicate cluster: the Core photos plus the currently
/// chosen keeper. Protected frames (favorite / edited / document — `Photo
/// .isProtected`) are never deletable by DEFAULT; the user can explicitly
/// force-reject them via the keyboard `⇧X` path or the mouse "include protected"
/// button, which both funnel through `setIncludeProtected` + a confirm dialog.
struct ReviewGroup: Identifiable {
    let id = UUID()
    var photos: [Photo]
    var keeperID: String
    /// Per-frame reject set: asset uuids the user wants deleted.
    /// SEEDED at scan time ONLY for verified exact-duplicate groups (see
    /// `seedExactRejections`); every other group seeds empty (keep all —
    /// the user decides). A frame is a deletion iff its uuid is in this set —
    /// `isDelete` and `deletionIDs` derive purely from here.
    var rejected: Set<String> = []
    /// The subset of `rejected` that the app itself seeded (exact-duplicate
    /// suggestions). Everything else in `rejected` came from an explicit user
    /// action. Kept so the audit log can attribute each deletion honestly
    /// (`.exactDuplicate` vs `.userRejected`). Any bulk user override
    /// (keep-all / reject-all / re-seed) clears this — from that point on the
    /// group's rejections are the user's, not the app's.
    var autoSeeded: Set<String> = []
    /// A confident, near-identical burst. Drives GROUPING/DISPLAY only (the
    /// "Near-identical" sidebar section): a confident group is near-identical
    /// but NOT proven interchangeable, so it never pre-seeds rejections.
    /// Deletion suggestions come exclusively from the exact-duplicate pass
    /// (`detectExactDuplicates` → `seedExactRejections`), which additionally
    /// byte-verifies the originals.
    ///
    /// FIX 4: default is FALSE — a group is uncertain until the scanner explicitly
    /// proves confidence (dHash spread ≤ threshold AND neural feature distance ≤
    /// threshold).
    var confidentDupe = false

    // SLICE-1 INVARIANT (unchanged from prior model):
    //   • The scanner NEVER seeds a protected frame into `rejected`.
    //   • A protected frame can only enter `rejected` via explicit user action
    //     (keyboard ⇧X or mouse "include protected") — both require confirmation.
    //   • `includeProtected` = true is the signal that the user has confirmed
    //     the override for this group. It gates the commit dialog.
    /// Set to true only after explicit user confirmation. Required for the
    /// final commit-delete to include any protected frame in this group.
    var includeProtected = false

    // MARK: - Derived state

    /// True when the user has explicitly cleared all rejections for this group.
    var keepAll: Bool { rejected.isEmpty }
    /// True when every non-protected frame (that isn't the keeper) is rejected.
    var deleteAll: Bool {
        // Same candidate set the `d` action seeds (Core `bulkRejectCandidates`):
        // keeper out, protected out, UNVERIFIABLE out. Asking whether frames the
        // bulk action is not allowed to mark are marked made `deleteAll` false
        // forever on any group holding an iCloud-evicted frame.
        let candidates = bulkRejectCandidates(photos: photos, keeperID: keeperID)
        guard !candidates.isEmpty else { return false }
        return candidates.isSubset(of: rejected)
    }

    /// The keeper AS IT WILL SURVIVE — the same definition the pre-commit sheet
    /// and `noSurvivorGroupCount` use (Core `survivingKeeper`). A keeper that is
    /// marked but protected-and-not-overridden still survives, so it is still
    /// the keeper; the two surfaces used to disagree about exactly that case and
    /// the sheet printed "no photo left" for a group the model counted as safe.
    func isKeeper(_ p: Photo) -> Bool {
        survivingKeeper(photos: photos, keeperID: keeperID,
                        rejected: rejected, includeProtected: includeProtected)?.uuid == p.uuid
    }
    /// Would this frame actually be removed? Delegates to the Core rule so the
    /// protection guarantee has exactly one implementation — and one that the
    /// test suite executes directly (see SnapsiftCore/DeleteDecision.swift).
    func isDelete(_ p: Photo) -> Bool {
        isEffectiveDeletion(p, rejected: rejected, includeProtected: includeProtected)
    }

    var spanSec: Double { (photos.last?.takenAt ?? 0) - (photos.first?.takenAt ?? 0) }
    var hasFavorite: Bool { photos.contains { $0.favorite } }
    var hasVideo: Bool { photos.contains { $0.kind == 1 } }
    var deletionIDs: [String] { photos.filter(isDelete).map(\.uuid) }
    /// Count of protected frames that are in `rejected` (regardless of includeProtected).
    var protectedDeletionCount: Int { photos.filter { $0.isProtected && rejected.contains($0.uuid) }.count }
    /// Count of protected frames in this group (regardless of armed state).
    var protectedCount: Int { photos.filter(\.isProtected).count }
    /// True when there are real frames that would be deleted.
    var effectivelyArmed: Bool { !deletionIDs.isEmpty }
}

/// Why a commit did nothing. "Blocked" and "nothing to delete" must not share
/// an exit code: the user confirmed a destructive action and is owed an answer.
enum CommitError: Error {
    /// Another library write (album sort, scan, face refine) is in flight.
    case busy
}

/// A semantic bucket from the "Similar sets" pass: all photos Vision tagged with
/// the same content label, across the whole library and across time.
struct CategoryBucket: Identifiable {
    let id = UUID()
    let label: String      // already a display-ready name (apfel or top Vision tag)
    let photos: [Photo]
    var count: Int { photos.count }
    var display: String { label }
}

/// Drives the whole app: PhotoKit authorization, enumeration → Core clustering,
/// thumbnail vending, and native (recoverable) deletion.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var groups: [ReviewGroup] = []
    @Published var isScanning = false
    /// True while `deleteReviewed` runs. Scans, face refines, album writes and
    /// snapshot flushes all gate on it: they mutate `groups` (or persist them),
    /// and racing a delete's post-await state rewrite corrupts both sides.
    @Published var isDeleting = false
    @Published var progress = ""
    @Published var includeVideo = false
    /// True once Apple's quality scores have been read from the library sidecar.
    @Published var qualityAvailable = false
    /// Whether the sidecar we read is provably the library PhotoKit serves.
    /// Anything but `.verified` means `edited` from that file is NOT trusted:
    /// cluster members fall back to the per-asset PhotoKit lookup, and whatever
    /// that cannot answer becomes `editedUndetermined` (⇒ protected) with a
    /// banner. Never silent — a degraded protection state the user can't see is
    /// indistinguishable from no protection at all.
    @Published var libraryIdentity: LibraryIdentity = .unverified(.pathUnknown)
    /// The sidecar may be trusted for PROTECTION facts, not merely for ranking.
    var sidecarTrusted: Bool { qualityAvailable && libraryIdentity.isVerified }
    /// Frames in the current review set whose edit state could not be read.
    /// Drives the degraded-protection banner.
    var undeterminedEditCount: Int {
        groups.reduce(0) { $0 + $1.photos.filter(\.editedUndetermined).count }
    }
    /// Exact-duplicate frames withheld from pre-marking because they carry (or
    /// might carry) album membership / a caption the keeper lacks.
    @Published var uniqueMetadataWithheld = 0
    /// Frames known to carry album membership / a caption the keeper lacks, so
    /// the pre-commit sheet can badge them even when the USER marked them by
    /// hand after the auto-seed declined to.
    @Published var uniqueMetadataIDs: Set<String> = []
    /// Deletions recovered from an interrupted commit's journal at launch.
    @Published var journalRecoveredCount: Int?
    /// Marks lost on restore because the photo itself is gone from the library.
    @Published var vanishedMarkCount: Int?
    /// Where the next scan reads its working set from. Default = whole library.
    @Published var scanSource: ScanSource = .wholeLibrary
    /// User albums fetched once after authorization (title + estimated count).
    /// Empty until `loadAlbums()` is called.
    @Published var albums: [AlbumItem] = []

    /// Max dHash Hamming distance for two burst frames to count as the same
    /// scene. Generous enough to keep real bursts (slight motion) together,
    /// tight enough to split unrelated shots.
    var contentMaxDistance = 14
    /// A cluster whose internal spread is at most this is a confident,
    /// near-identical burst (pre-marked for deletion). Tuned on real avalanche
    /// bursts: median spread 3, p75 6 — so ≤6 captures ~86% of genuine
    /// held-shutter bursts while pose/subject changes (≈12) fall to "you decide".
    var contentConfidentSpread = 6
    /// Before a frame is *ever* pre-marked for deletion, the cluster must also be
    /// neurally near-identical, not just dHash-close (dHash can't tell "same
    /// framing, subject moved" from a true duplicate). A pre-marked deletion needs
    /// max pairwise feature distance ≤ this; a moved-subject pair (≈0.2+) falls to
    /// "you decide". Tight on purpose — wrongly deleting a keeper breaks trust,
    /// while missing a duplicate is harmless.
    var contentConfidentFeature: Float = 0.10
    @Published var refiningFaces = false
    /// True once a face-refinement pass has re-picked keepers.
    @Published var facesApplied = false
    /// Semantic category buckets from the "Similar sets" pass. When non-empty the
    /// UI is in browse mode (categories), not cluster-review mode.
    @Published var categories: [CategoryBucket] = []
    var browseMode: Bool { !categories.isEmpty }
    /// Free-text filter over categories (browse mode).
    @Published var searchQuery = "" { didSet { apfelMatched = nil } }
    /// Labels apfel semantically matched for the current query (nil = substring).
    @Published var apfelMatched: Set<String>?
    @Published var apfelSearching = false
    var apfelAvailable: Bool { Apfel.isInstalled }

    /// ReviewGroup IDs that passed the exact-duplicate predicate (dHash distance 0
    /// + feature-print ≈0 + same dimensions). Populated by `detectExactDuplicates`
    /// after a look-alike scan. Empty until that pass runs.
    @Published var exactDupeGroupIDs: Set<ReviewGroup.ID> = []
    /// True while album-write is in progress.
    @Published var isWritingAlbums = false
    /// True once any scan has completed (even with zero results) — lets the UI
    /// distinguish "haven't scanned yet" from "scanned, nothing found".
    @Published var hasScanned = false
    /// One-shot completion notice for the UI banner ("found N sets" / "nothing
    /// found" / "album gone"). The view shows it and sets it back to nil.
    @Published var scanNotice: String?
    /// Set when a stale-token restore dropped app-seeded suggestions (see
    /// `restoreSnapshot`). Drives a PERSISTENT inline bar — this outlives the 3.2 s
    /// launch banner because the user is least likely to be watching at launch and
    /// the consequence (their pre-marks are gone) needs a standing pointer to rescan.
    /// Nil = no standing notice; cleared on rescan or dismissal.
    @Published var staleRestoreClearedCount: Int?
    /// True when the most recent commit deleted photos but its audit line couldn't
    /// be written (e.g. full disk) — the delete still stands, but the accountability
    /// record is missing and the completion banner must say so.
    @Published var lastDeleteAuditFailed = false
    /// One-shot: a snapshot write failed (e.g. full disk) and the user hasn't been
    /// told this session. The view observes it, banners a disk-full warning, and
    /// resets it. The private `snapshotWriteFailedNotified` latch guards re-raising.
    @Published var snapshotSaveFailedNotice = false
    /// A snapshot file existed but couldn't be decoded (corrupt / stale schema).
    /// One-shot: the view banners it and resets. The unreadable bytes are kept
    /// aside as last-scan.unreadable.json by ScanSnapshotStore.
    @Published var snapshotUnreadableNotice = false
    /// Overall scan completion 0…1 for the determinate progress bar; nil while
    /// in a phase whose length is unknown (fetch, quality sidecar).
    @Published var progressFraction: Double?

    // MARK: - Scan lifecycle (cancel + restore)

    enum ScanKind: String { case burst, lookAlikes, similarSets }

    /// The driving task of the in-flight scan; cancelling it threads
    /// Task.isCancelled through every structured loop in the pipeline.
    private var scanTask: Task<Void, Never>?
    /// Detached work (the quality-sidecar read) does not inherit the scan
    /// task's cancellation — it polls this flag instead.
    private final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
    private var abortFlag = AbortFlag()
    private(set) var lastScanKind: ScanKind = .burst
    private var snapshotSaveTask: Task<Void, Never>?
    /// Enqueue time of the last full snapshot save — drives the max-deferral cap in
    /// `scheduleSnapshotSave` so a keystroke cadence faster than the debounce window
    /// can't re-arm the timer forever and leave a whole session unpersisted.
    private var lastSnapshotWrite = Date.distantPast
    /// Latched so repeated debounced write failures (e.g. a full disk) surface once
    /// per session, not per keystroke; reset on the next successful write so a later
    /// relapse re-notifies.
    private var snapshotWriteFailedNotified = false

    /// Launch a scan as a cancellable task. UI entry point for all three kinds.
    /// A running face-refine mutates keepers concurrently, so the two pipelines
    /// are mutually exclusive here (and again in `refineWithFaces`).
    func startScan(_ kind: ScanKind, _ t: L10n) {
        // isWritingAlbums: writeAlbums suspends across performChanges and then
        // saves a snapshot — a scan started in that window would wipe `groups`
        // out from under it (the save itself is also guarded, belt-and-braces).
        guard !isScanning, !refiningFaces, !isDeleting, !isWritingAlbums else { return }
        // Set synchronously — the scan method body runs in a separately-enqueued
        // task, and a guard that only trips once the body executes lets a second
        // startScan in the same runloop turn clobber scanTask/abortFlag (Cancel
        // would then cancel the wrong task).
        isScanning = true
        // A debounced decision-save must never fire after the scan wipes
        // `groups` — it would atomically replace the snapshot (thousands of
        // review decisions) with an empty one.
        snapshotSaveTask?.cancel()
        // A fresh scan re-proves everything, so the standing stale-restore notice
        // no longer applies.
        staleRestoreClearedCount = nil
        lastScanKind = kind
        abortFlag = AbortFlag()
        scanTask = Task { [weak self] in
            guard let self else { return }
            switch kind {
            case .burst:       await self.scan(t)
            case .lookAlikes:  await self.scanLookAlikes(t)
            case .similarSets: await self.scanSimilarSets(t)
            }
        }
    }

    /// Cancel the in-flight scan OR face-refine. The pipeline drains
    /// cooperatively; a scan notices the cancellation and calls
    /// `finishCancelledScan`, a refine bails and keeps its partial face scores.
    func cancelScan() {
        guard isScanning || refiningFaces else { return }
        abortFlag.set()
        scanTask?.cancel()
    }

    /// Discard the half-built state of a cancelled scan and quietly restore the
    /// previous snapshot (if any) so cancelling never destroys prior work.
    private func finishCancelledScan(_ t: L10n) {
        // The scan method's defer hasn't run yet — clear the flag here so the
        // snapshot restore below isn't blocked by its own !isScanning guard.
        isScanning = false
        groups = []
        categories = []
        exactDupeGroupIDs = []
        progressFraction = nil
        // An aborted sidecar read returns an EMPTY map — caching that would
        // permanently disable quality ranking for the session. Forget it so
        // the next scan reads it properly.
        if enrichment?.isEmpty ?? false { enrichment = nil }
        // The quiet restore now decodes + re-fetches off the main actor (see
        // restoreSnapshot) so pressing Cancel never trades one stall for another;
        // surface the cancelled notice immediately and let the restore land after.
        scanNotice = t.scanCancelled()
        Task { [weak self] in await self?.restoreSnapshot(t, quiet: true) }
    }

    /// True (and cleans up) when the scan task was cancelled mid-pipeline.
    private func bailIfCancelled(_ t: L10n) -> Bool {
        guard Task.isCancelled || abortFlag.isSet else { return false }
        finishCancelledScan(t)
        return true
    }

    /// Categories after the search filter: apfel's semantic match if it ran,
    /// otherwise a plain substring match — and everything when the query is empty.
    var filteredCategories: [CategoryBucket] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return categories }
        if let matched = apfelMatched { return categories.filter { matched.contains($0.label) } }
        return categories.filter {
            $0.label.lowercased().contains(q) || $0.display.lowercased().contains(q)
        }
    }

    /// Refine the current query semantically via apfel (no-op if unavailable).
    func runApfelSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, apfelAvailable, !apfelSearching else { return }
        apfelSearching = true
        defer { apfelSearching = false }
        let labels = categories.map(\.label)
        if let matched = await Apfel.match(query: q, labels: labels) {
            apfelMatched = Set(matched)
        }
    }

    private var enrichment: [String: QualitySidecar.Enrichment]?
    /// The database `enrichment` was actually read from (see `loadEnrichmentIfNeeded`).
    private var sidecarPath = ""
    private var faceScores: [String: Double] = [:]

    // Clustering knobs (match the Python defaults).
    var gapSec = 3.0
    var sizeTol = 0.10
    var maxSpan = 30.0

    let imageManager = PHCachingImageManager()
    private var assetsByID: [String: PHAsset] = [:]

    /// The library-state change token as of when the current review verdicts were
    /// last known valid (scan end, or restore). `makeSnapshot` persists THIS verbatim
    /// rather than re-reading "now" on every keystroke — re-stamping per decision
    /// would silently re-bless scan-time exact verdicts against a library an external
    /// edit may have changed, so `restoreSnapshot`'s stale demotion (the sole cross-
    /// launch staleness guard) would never fire. Advanced only after snapsift's OWN
    /// library writes, and only when it was still current going in — see
    /// `restampTokenAfterOwnWrite`.
    private var scanChangeToken: Data?

    // MARK: - Pass 2a — non-destructive display rotation
    //
    // Session-only clockwise quarter-turns (0…3) per asset uuid, applied to the
    // RENDERED thumbnail + loupe and to the aspect ratio fed into the justified
    // gallery (so a rotated portrait reflows as a landscape). This is purely a
    // display transform — NOTHING is ever written back to Photos in this pass.
    // The map is cleared on every rescan (rotations don't survive a fresh scan).
    @Published private(set) var displayRotation: [String: Int] = [:]

    // MARK: - Pass 2b — save rotation to Photos (reversible)
    //
    // User-initiated, deliberate, confirmed write of a display rotation back to
    // Photos via PHContentEditingOutput + PHAdjustmentData. The original is
    // preserved by Photos; the user can "Revert to Original" at any time.
    //
    // Saving marks the photo as edited (PHAdjustmentData present, and the
    // library's ZADJUSTMENTSSTATE flips with it), so the sidecar-backed
    // `edited` flag reads true and snapsift will then treat the frame as a
    // protected frame. This is expected and is disclosed in the confirmation
    // dialog.

    /// True when the save-rotation confirmation alert should be shown.
    @Published var showSaveRotationConfirm = false
    /// Set when a save-rotation write fails — shown as a persistent error alert.
    @Published var saveRotationError: Error?
    /// True after a successful save — drives the success banner.
    @Published var saveRotationSuccess = false

    /// Current display quarter-turns for a frame (0 when unrotated).
    func rotation(for id: String) -> Int { displayRotation[id] ?? 0 }

    /// Rotate a frame 90° for display only. `clockwise` false = counter-clockwise
    /// (⇧R). Normalised into 0…3. Session-only; never written to Photos.
    func rotate(frameID: String, clockwise: Bool) {
        let cur = displayRotation[frameID] ?? 0
        let next = (((cur + (clockwise ? 1 : -1)) % 4) + 4) % 4
        if next == 0 { displayRotation.removeValue(forKey: frameID) }
        else { displayRotation[frameID] = next }
    }

    /// Aspect ratio (width / height) for layout, orientation-corrected by the
    /// asset's natural dimensions (PHAsset.pixelWidth/Height are already EXIF-
    /// upright) AND by the current display rotation: an odd quarter-turn swaps
    /// width and height so a rotated portrait reflows as a landscape.
    func displayAspect(for p: Photo) -> Double {
        let w = Double(max(p.width, 1)), h = Double(max(p.height, 1))
        let base = w / h
        let q = rotation(for: p.uuid)
        return (q == 1 || q == 3) ? (1.0 / base) : base
    }

    // MARK: - Pass 2b — save rotation to Photos

    /// Save the focused frame's pending display rotation permanently to the
    /// user's Photos library. Reversible: Photos retains the original and
    /// surfaces "Revert to Original" because we write PHAdjustmentData.
    ///
    /// Must only be called after user confirmation (the UI shows an alert first).
    /// On success, removes the frame from `displayRotation` (the rotation is now
    /// baked into the asset; PhotoKit will return the photo upright on next fetch).
    /// On failure, sets `saveRotationError` for the UI to surface.
    @MainActor
    func saveRotationToPhotos(frameID: String) async {
        let quarterTurns = rotation(for: frameID)
        let net = ((quarterTurns % 4) + 4) % 4
        guard net != 0 else { return }
        guard let asset = assetsByID[frameID] else {
            saveRotationError = RotationSaveError.noEditingInput
            return
        }
        // REFUSED on an already-edited frame. PhotoKit hands us the RENDERED
        // version of an adjusted asset (we don't set canHandleAdjustmentData),
        // so saving would bake the user's existing crop/filter into a fresh JPEG
        // and replace their adjustment chain with ours — "Revert to Original"
        // would then throw away that crop too. The confirmation text promises
        // the opposite ("the original is preserved — you can Revert at any
        // time"), and this doctrine's own words are that edited frames are
        // sacred. This is the app's only path that REWRITES a photo, so it is
        // the one place that rule has to be enforced rather than described.
        if groups.contains(where: { g in g.photos.contains { $0.uuid == frameID && $0.edited } }) {
            saveRotationError = RotationSaveError.frameAlreadyEdited
            return
        }
        let wasCurrent = ScanSnapshotStore.changeTokenIsCurrent(scanChangeToken)
        do {
            try await saveRotation(asset: asset, quarterTurns: net)
            // The saved rotation writes PHAdjustmentData → the asset is now
            // EDITED, i.e. protected. Reflect that in-model immediately so every
            // guard (reject-all, isDelete, audit reason) treats the frame as
            // protected THIS session — not only after a rescan, as the pass-2b
            // comment promised — and pull it out of any delete bucket it sat in.
            for i in groups.indices {
                guard let j = groups[i].photos.firstIndex(where: { $0.uuid == frameID }) else { continue }
                groups[i].photos[j] = groups[i].photos[j].with(edited: true)
                groups[i].rejected.remove(frameID)
                groups[i].autoSeeded.remove(frameID)
            }
            // Success: clear the display rotation — the asset is now baked.
            displayRotation.removeValue(forKey: frameID)
            saveRotationSuccess = true
            // Our own write advanced the library token; move the reference so a
            // relaunch doesn't discard every exact pre-mark over our rotation,
            // and persist the corrected `edited` flag with the new token.
            restampTokenAfterOwnWrite(wasCurrent: wasCurrent, ourIDs: [frameID])
            saveSnapshotNow()
        } catch {
            saveRotationError = error
        }
    }

    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }

    /// Marks the USER made (rejections minus app-seeded ones). A rescan
    /// re-derives auto-seeds but can never reconstruct these — so this is the
    /// count the rescan confirmation warns about.
    var userMarkCount: Int {
        groups.reduce(0) { $0 + $1.rejected.subtracting($1.autoSeeded).count }
    }

    /// Confident, near-identical bursts (pre-marked) vs groups whose frames vary
    /// enough that the user should decide (nothing pre-marked).
    var confidentGroups: [ReviewGroup] { groups.filter(\.confidentDupe) }
    var pendingGroups: [ReviewGroup] { groups.filter { !$0.confidentDupe } }

    /// Total bytes that would be freed by deleting every marked frame (0 if the
    /// quality sidecar — which carries real file sizes — wasn't readable).
    var reclaimableBytes: Int {
        groups.reduce(0) { acc, g in
            acc + g.deletionIDs.compactMap { id in g.photos.first { $0.uuid == id } }
                .reduce(0) { $0 + $1.size }
        }
    }

    func asset(for id: String) -> PHAsset? { assetsByID[id] }

    func requestAccess() async {
        auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Populate `albums` from the Photos library (title + estimated count only —
    /// no pixels, no network). Call once after the user grants access.
    func loadAlbums() {
        albums = fetchUserAlbums()
    }

    func scan(_ t: L10n) async {
        progress = t.progFetching()
        defer { isScanning = false; progress = ""; progressFraction = nil }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeAllBurstAssets = true
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        // Scope to the chosen source (whole library or a single album). If the
        // album can no longer be resolved (deleted since the picker showed it),
        // bail early rather than silently falling back to the whole library —
        // and BEFORE the state wipe below, so a scan that never ran leaves the
        // previous session's review state untouched (same stance as cancel).
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            // The defer wipes `progress` on return, so the album-gone message must
            // travel via the one-shot notice or the user never sees why nothing ran.
            scanNotice = t.progAlbumGone()
            return
        }

        await LookAlikeScanner.clearCache()   // pixels may have changed since last scan
        groups = []
        categories = []
        assetsByID = [:]
        facesApplied = false
        displayRotation = [:]   // Pass 2a: rotations don't survive a rescan
        exactDupeGroupIDs = []  // stale exact verdicts never outlive a rescan
        uniqueMetadataWithheld = 0
        uniqueMetadataIDs = []

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        // FIX 1 — Live Photo paired-video guard (off the main actor; see
        // excludeLivePhotoPairedVideos). Only relevant when videos are included.
        var pairedVideoUndetermined = 0
        if includeVideo {
            (assets, pairedVideoUndetermined) = await excludeLivePhotoPairedVideos(assets)
        }
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(assets.count)
        for a in assets { map[a.localIdentifier] = a }
        assetsByID = map

        // Enrich with Apple's quality scores + real file size from the library's
        // Photos.sqlite (read-only). A SUCCESSFUL load is cached for the session;
        // an empty one (no Full Disk Access / non-standard path / aborted) is
        // re-probed on every scan — otherwise granting FDA mid-session would
        // change nothing until relaunch, with no hint why quality is still off.
        // The re-probe costs one failed sqlite open per scan for a no-FDA user.
        await loadEnrichmentIfNeeded(t, newestFirst: assets)
        if bailIfCancelled(t) { return }
        let enr = enrichment ?? [:]
        // Chunked with yields: a 120K-asset map monopolises the main actor for
        // long enough that even the Cancel click can't be processed.
        var enriched: [Photo] = []
        enriched.reserveCapacity(assets.count)
        for chunk in stride(from: 0, to: assets.count, by: 2000) {
            if bailIfCancelled(t) { return }
            for a in assets[chunk..<min(chunk + 2000, assets.count)] {
                enriched.append(makePhoto(from: a, enr: enr))
            }
            await Task.yield()
        }

        progress = t.progClustering(enriched.count)
        progressFraction = 0.15
        let clustered = cluster(enriched, gapSec: gapSec, sizeTol: sizeTol, maxSpan: maxSpan)

        // Always content-verify (no opt-out): a time-burst is only real if the
        // frames actually look alike, so two different shots taken seconds apart
        // can never be grouped on timing alone. We tier by how much the frames
        // differ — near-identical → confident (pre-marked), more variation →
        // "you decide" (nothing pre-marked). Reliability over speed, always.
        progress = t.progVerifying(0, clustered.count)
        let lookup = assetsByID
        let verified = await LookAlikeScanner.verifyByContent(
            clustered, asset: { lookup[$0] }, manager: imageManager,
            maxDistance: contentMaxDistance, t: t
        ) { [weak self] msg, frac in
            Task { @MainActor in
                self?.progress = msg
                if let frac { self?.progressFraction = 0.15 + 0.45 * frac }
            }
        }
        if bailIfCancelled(t) { return }
        // Neural gate: a cluster only stays "confident" (→ pre-marks a deletion)
        // if Apple's feature print agrees it's near-identical. dHash is cheap
        // recall; this is the precise arbiter that keeps the scan from ever
        // suggesting you delete a frame that's actually a different moment. Only
        // dHash-confident clusters can pre-mark, so only those need the (pricier)
        // neural check — run as one bounded-concurrency batch, not cluster-by-
        // cluster, so unreadable-thumbnail timeouts overlap instead of summing.
        let confidentIdx = verified.indices.filter { verified[$0].spread <= contentConfidentSpread }
        let toCheck = confidentIdx.map { verified[$0].photos.map(\.uuid) }
        let spreads = await LookAlikeScanner.featureSpreads(
            toCheck, byID: assetsByID, manager: imageManager
        ) { [weak self] done, total, loaded in
            Task { @MainActor in
                self?.progress = t.progConfirming(done, total, loaded: loaded)
                if total > 0 { self?.progressFraction = 0.6 + 0.2 * Double(done) / Double(total) }
            }
        }
        if bailIfCancelled(t) { return }
        var neuralConfident = Set<Int>()
        for (k, idx) in confidentIdx.enumerated() {
            if let fs = spreads[k], fs <= contentConfidentFeature { neuralConfident.insert(idx) }
        }
        // Fill pixel-based flags (document protection + sharpness ranking) over
        // just the verified cluster members, then build each group from the
        // enriched photos so the keeper respects sharpness and documents are
        // protected. Index-aligned with `verified` so the confident flags line up.
        let flagged = await enrichFlags(verified.map(\.photos)) { done, total in
            self.progress = t.progVerifying(done, total)
            if total > 0 { self.progressFraction = 0.8 + 0.1 * Double(done) / Double(total) }
        }
        if bailIfCancelled(t) { return }
        var built: [ReviewGroup] = []
        for (idx, photos) in flagged.enumerated() {
            let confident = neuralConfident.contains(idx)
            let keep = keeper(photos)
            var g = ReviewGroup(photos: photos, keeperID: keep.uuid)
            g.confidentDupe = confident
            // DOCTRINE: near-identical is not identical. Confident groups are
            // sectioned separately but NOTHING is pre-marked — only the exact-
            // duplicate pass below (perceptual bar + byte verification) may seed.
            built.append(g)
        }

        // Exact-duplicate pass: the ONLY source of pre-marked deletions. Runs
        // on the local array — `groups` is published exactly once, fully
        // seeded, so the review UI can never interleave with the seeder (a
        // mid-seed user decision being overridden, or a mid-seed delete
        // shifting indices under the loop).
        let exact = await detectExactDuplicates(in: built, t, fracBase: 0.9, fracSpan: 0.06)
        built = await seedExactRejections(in: built, exact: exact, t, fracBase: 0.96, fracSpan: 0.04)
        if bailIfCancelled(t) { return }
        groups = built
        exactDupeGroupIDs = exact

        progressFraction = 1.0
        hasScanned = true
        // Verdicts were just proven against the CURRENT library — anchor the
        // staleness reference here (see `scanChangeToken`).
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        var doneNotice = groups.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(groups.count)
        if pairedVideoUndetermined > 0 {
            doneNotice += " " + t.scanPairedVideosSkipped(pairedVideoUndetermined)
        }
        scanNotice = doneNotice
        await releaseScanCaches()
        // Unguarded variant: this pipeline's own defer hasn't cleared
        // `isScanning` yet, and `groups` is complete here by construction.
        saveSnapshotIgnoringScanState()
    }

    /// Release scan-only working memory once verdicts are materialized into
    /// `groups`/`categories`: the per-scan hash/feature-print cache exists only to
    /// dedupe work WITHIN a scan (a rescan rebuilds it) and the full-library
    /// `assetsByID` map retains a PHAsset per library asset even though every
    /// post-scan consumer (thumbnails, face refine, album write, delete) only ever
    /// looks up group/category members. Called at the very end of each scan so the
    /// exact-duplicate pass (which deliberately reuses the cache) still gets its
    /// hits, then hundreds of MB aren't held while the user merely browses results.
    private func releaseScanCaches() async {
        await LookAlikeScanner.clearCache()
        let memberIDs = Set(groups.flatMap { $0.photos.map(\.uuid) }
            + categories.flatMap { $0.photos.map(\.uuid) })
        assetsByID = assetsByID.filter { memberIDs.contains($0.key) }
    }

    /// Drop Live Photo paired videos — the independent `.mov` companion that
    /// appears as its own PHAsset only when videos are included. Deleting one
    /// orphans the still (motion is permanently lost and the pair is NOT
    /// recoverable together from Recently Deleted), so it must never enter a
    /// deletable set. The still side is left in — deleting a Live Photo still
    /// removes both halves atomically and recoverably; only the lone video is
    /// dangerous.
    ///
    /// `PHAssetResource.assetResources(for:)` is a synchronous per-asset XPC
    /// round-trip; running it inside the main-actor enumeration froze the UI for
    /// minutes on a video-heavy library (the same stall makePhoto documents for
    /// `edited`). Every lookup therefore goes through `PhotoKitSyncLane` —
    /// off the cooperative pool, timeout-guarded — and the abort flag is
    /// honoured between items so Cancel stays responsive.
    ///
    /// SAFETY DIRECTION on a lane timeout (photolibraryd unresponsive): a
    /// video whose pairing we could not determine is treated as paired and
    /// EXCLUDED from the scan. Under-scanning only hides suggestions; guessing
    /// "not paired" could put a Live Photo's motion half into a deletable set,
    /// where deleting it destroys the pair unrecoverably. `undetermined`
    /// counts those exclusions so the scan-complete banner can say so instead
    /// of silently narrowing scope.
    private func excludeLivePhotoPairedVideos(_ assets: [PHAsset]) async
        -> (kept: [PHAsset], undetermined: Int) {
        let videos = assets.filter { $0.mediaType == .video }
        guard !videos.isEmpty else { return (assets, 0) }
        var excluded: Set<String> = []
        var undetermined = 0
        for v in videos {
            if abortFlag.isSet { break }   // scan is cancelling; result unused
            let paired: Bool? = await PhotoKitSyncLane.call {
                PHAssetResource.assetResources(for: v).contains {
                    $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
                }
            }
            // `default`, not `case nil`: Swift 5.10 (the CI toolchain) does not
            // accept true/false/nil over `Bool?` as exhaustive, and an
            // exhaustiveness error must never be answered by guessing which case
            // is missing. The default arm is the UNDETERMINED one and it
            // EXCLUDES the video — cannot verify ⇒ cannot delete, the same
            // direction every other unknown takes in this file.
            switch paired {
            case .some(true):
                excluded.insert(v.localIdentifier)
            case .some(false):
                break
            default:
                excluded.insert(v.localIdentifier)
                undetermined += 1
            }
        }
        guard !excluded.isEmpty else { return (assets, 0) }
        return (assets.filter { !excluded.contains($0.localIdentifier) }, undetermined)
    }

    /// Build a Core Photo from a PHAsset, enriched with Apple quality + size.
    ///
    /// STRICTLY cheap metadata only. `edited` now IS cheap: it rides the same
    /// sidecar row as quality/size (`ZASSET.ZADJUSTMENTSSTATE`), zero XPC.
    /// It must never go back to per-asset PhotoKit lookups here: the
    /// `PHAssetResource.assetResources` variant cost an XPC round-trip per
    /// asset — mapping the whole library through it was the real "reading
    /// quality scores" multi-minute stall (sampled live: ~80% of scan wall
    /// time), and the same sync XPC later wedged a scan for >24 h when
    /// photolibraryd restarted mid-call. Without Full Disk Access the sidecar
    /// is empty and `edited` starts false; enrichFlags upgrades cluster
    /// members via the wedge-proof PhotoKit fallback.
    /// How many of the newest assets are sampled to prove the sidecar is LIVE
    /// (see `loadEnrichmentIfNeeded`). Small — the question is binary.
    private static let identitySampleSize = 12

    /// Read the quality sidecar when we don't already have a usable one, and —
    /// the part that decides whether anything may be deleted — establish whether
    /// the file we just read is the library PhotoKit is serving.
    ///
    /// Two ways to be reading the wrong bytes, both silent before this:
    ///   • WRONG FILE. A library COPIED (not moved) to an external disk and then
    ///     made the system library leaves a complete stale duplicate at
    ///     ~/Pictures. Same asset UUIDs, same schema. Every lookup succeeds and
    ///     every answer is months old — including `edited`, the one flag standing
    ///     between an edited photo and Recently Deleted. We now read the path
    ///     Photos itself records, and treat "couldn't establish it" as a
    ///     mismatch rather than as permission to trust the default path.
    ///   • RIGHT FILE, FROZEN. A restored snapshot at the right path. Probed by
    ///     asking whether the newest assets PhotoKit can see exist in the
    ///     database at all — through the WAL-aware read, because the bulk `load`
    ///     opens `immutable=1` and by design never sees the last few minutes.
    ///
    /// `newestFirst` must be the scan's asset list; all three call sites fetch
    /// sorted by creationDate ASCENDING, so the newest are at the tail.
    private func loadEnrichmentIfNeeded(_ t: L10n, newestFirst assets: [PHAsset]) async {
        guard enrichment?.isEmpty != false else { return }
        progress = t.progReadingQuality()
        progressFraction = nil   // length unknown — indeterminate
        let flag = abortFlag
        let loc = QualitySidecar.locate()
        sidecarPath = loc.path
        enrichment = await Task.detached(priority: .userInitiated) {
            QualitySidecar.load(libraryPath: loc.path, shouldAbort: { flag.isSet })
        }.value
        qualityAvailable = !(enrichment?.isEmpty ?? true)
        guard qualityAvailable else {
            // Nothing was read, so there is nothing to trust; the existing Full
            // Disk Access hint already explains this case.
            libraryIdentity = .unverified(.pathUnknown)
            return
        }
        let sample = assets.suffix(200)
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .prefix(Self.identitySampleSize)
            .map { QualitySidecar.zuuid(fromLocalIdentifier: $0.localIdentifier) }
        let path = loc.path
        let known = await Task.detached(priority: .userInitiated) {
            QualitySidecar.editedFlags(zuuids: sample, libraryPath: path)
        }.value
        libraryIdentity = evaluateLibraryIdentity(
            sidecarPath: loc.path,
            photosLibraryPath: loc.photosLibraryPath,
            sampledNewest: sample.count,
            foundInSidecar: known?.count ?? 0)
    }

    private func makePhoto(from asset: PHAsset, enr: [String: QualitySidecar.Enrichment]) -> Photo {
        let id = asset.localIdentifier
        let e = enr[QualitySidecar.zuuid(fromLocalIdentifier: id)]
        let uti = (asset.value(forKey: "uniformTypeIdentifier") as? String) ?? ""
        let name = (asset.value(forKey: "filename") as? String) ?? ""
        return Photo(uuid: id, filename: name,
                     takenAt: asset.creationDate?.timeIntervalSince1970 ?? 0,
                     width: asset.pixelWidth, height: asset.pixelHeight,
                     size: e?.size ?? 0, uti: uti,
                     kind: asset.mediaType == .video ? 1 : 0,
                     favorite: asset.isFavorite, quality: e?.quality ?? 0,
                     // `edited` is only a FACT when the sidecar is provably the
                     // live library; otherwise it starts UNDETERMINED (⇒
                     // protected) and enrichFlags upgrades cluster members via
                     // the wedge-proof per-asset PhotoKit fallback.
                     edited: sidecarTrusted ? (e?.edited ?? false) : false,
                     originalCamera: PhotoFlags.originalCamera(asset),
                     editedUndetermined: !sidecarTrusted)
    }

    /// Fill the per-frame flags that are too expensive for the whole library —
    /// `isDocument`/`sharpness` (Vision/pixels) — over cluster members only.
    /// Returns the clusters with those photos rebuilt; quality/size/edited
    /// (from `makePhoto`) are preserved.
    /// Bounded concurrency with a per-image timeout, like the scanners, so a stuck
    /// thumbnail can't stall it.
    ///
    /// `edited` normally arrives from the sidecar at Photo-build time (zero
    /// XPC). Only when the sidecar is unreadable (no Full Disk Access) is it
    /// upgraded here per cluster member — and then ONLY via
    /// `PhotoFlags.editedFallback`: the raw PhotoKit lookup is a synchronous
    /// XPC round-trip that wedged a scan for >24 h when photolibraryd
    /// restarted mid-call, all 8 workers convoyed behind one dead queue with
    /// no way to observe cancellation. The fallback confines that risk to a
    /// single sacrificial thread with a timeout + breaker.
    ///
    /// FIX #4: uses `PhotoFlags.isDocumentResult` (returns `(isDocument, degraded)`)
    /// instead of the plain bool variant so we can record whether the Vision pass
    /// was actually able to see the image. A `degraded = true` result means the
    /// original was iCloud-evicted or timed out — `isDocument` is unreliable in
    /// that case and the Photo is marked `documentEvalDegraded = true` so the caller
    /// can withhold auto-seeding.
    private func enrichFlags(_ clusters: [[Photo]],
                             progress: (Int, Int) -> Void) async -> [[Photo]] {
        let uuids = Array(Set(clusters.flatMap { $0.map(\.uuid) }))
        var docs: [String: Bool] = [:]
        var docsDegraded: [String: Bool] = [:]
        var sharps: [String: Double] = [:]
        var edits: [String: Bool] = [:]
        var done = 0
        let lookup = assetsByID
        // Fall back to the per-asset PhotoKit lookup whenever the sidecar can't
        // be trusted for protection — no Full Disk Access, OR a database we
        // could not prove is the library PhotoKit serves.
        let needEditedFallback = !sidecarTrusted
        await withTaskGroup(of: (String, Bool, Bool, Double, Bool?).self) { group in
            var next = 0
            let limit = 8
            func add() {
                while !Task.isCancelled, next < uuids.count {   // cooperative cancel
                    let id = uuids[next]; next += 1
                    guard let a = lookup[id] else { continue }
                    let mgr = imageManager
                    group.addTask {
                        // One thumbnail fetch, fed to BOTH the document check and
                        // the sharpness estimate — they previously fetched the same
                        // 512px thumbnail independently (double I/O per member).
                        let localCG = await PhotoFlags.localThumb(a, mgr)
                        async let docResult = PhotoFlags.isDocumentResult(a, manager: mgr, localCG: localCG)
                        let edited: Bool? = needEditedFallback
                            ? await PhotoFlags.editedFallback(a) : nil
                        let shp = localCG.map(PhotoFlags.sharpness(from:)) ?? 0
                        let (isDoc, degraded) = await docResult
                        return (id, isDoc, degraded, shp, edited)
                    }
                    return
                }
            }
            for _ in 0..<limit { add() }
            for await (id, doc, degraded, shp, edited) in group {
                docs[id] = doc
                docsDegraded[id] = degraded
                sharps[id] = shp
                if let edited { edits[id] = edited }
                done += 1
                if done % 25 == 0 { progress(done, uuids.count) }
                add()
            }
        }
        return clusters.map { cluster in
            cluster.map { p in
                Photo(uuid: p.uuid, filename: p.filename, takenAt: p.takenAt,
                      width: p.width, height: p.height, size: p.size, uti: p.uti,
                      kind: p.kind, favorite: p.favorite, quality: p.quality,
                      edited: edits[p.uuid] ?? p.edited,
                      isDocument: docs[p.uuid] ?? p.isDocument,
                      sharpness: sharps[p.uuid] ?? p.sharpness,
                      originalCamera: p.originalCamera,
                      documentEvalDegraded: docsDegraded[p.uuid] ?? p.documentEvalDegraded,
                      // The fallback only reports what it could DETERMINE, so a
                      // missing entry is not "not edited" — it is "we don't
                      // know", which is a protection, not a permission.
                      editedUndetermined: needEditedFallback ? (edits[p.uuid] == nil) : false)
            }
        }
    }

    /// L3 cross-time pass: dHash-candidate + neural feature-print confirmation
    /// over the chosen source. Heavier than the burst scan — shows progress.
    func scanLookAlikes(_ t: L10n) async {
        progress = t.progFetching()
        defer { isScanning = false; progress = ""; progressFraction = nil }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        // Bail BEFORE the state wipe (see scan()) — a scan that never ran must
        // leave the previous session's review state untouched.
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            // The defer wipes `progress` on return, so the album-gone message must
            // travel via the one-shot notice or the user never sees why nothing ran.
            scanNotice = t.progAlbumGone()
            return
        }

        await LookAlikeScanner.clearCache()   // pixels may have changed since last scan
        groups = []
        categories = []
        facesApplied = false
        displayRotation = [:]   // Pass 2a: rotations don't survive a rescan
        exactDupeGroupIDs = []  // stale exact verdicts never outlive a rescan
        uniqueMetadataWithheld = 0
        uniqueMetadataIDs = []

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a) }
        // FIX 1 — Live Photo paired-video guard (off the main actor; see scan()).
        var pairedVideoUndetermined = 0
        if includeVideo {
            (assets, pairedVideoUndetermined) = await excludeLivePhotoPairedVideos(assets)
        }
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(assets.count)
        for a in assets { map[a.localIdentifier] = a }
        assetsByID = map

        await loadEnrichmentIfNeeded(t, newestFirst: assets)
        if bailIfCancelled(t) { return }
        let enr = enrichment ?? [:]

        let idGroups = await LookAlikeScanner.scan(assets: assets, manager: imageManager, t: t) { [weak self] msg, frac in
            Task { @MainActor in
                self?.progress = msg
                if let frac { self?.progressFraction = 0.05 + 0.65 * frac }
            }
        }
        if bailIfCancelled(t) { return }

        let raw = idGroups.compactMap { ids -> [Photo]? in
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            return photos.count >= 2 ? photos : nil
        }
        // Document protection + sharpness ranking over the cluster members only.
        let enriched = await enrichFlags(raw) { done, total in
            self.progress = t.progVerifying(done, total)
            if total > 0 { self.progressFraction = 0.7 + 0.15 * Double(done) / Double(total) }
        }
        if bailIfCancelled(t) { return }
        var built = enriched.map { photos in
            // Look-alike groups are not auto-pre-marked (user decides).
            ReviewGroup(photos: photos, keeperID: keeper(photos).uuid)
        }

        // Exact-duplicate pass: the ONLY source of pre-marked deletions.
        // Local array, single publish — same reasoning as scan().
        let exact = await detectExactDuplicates(in: built, t, fracBase: 0.85, fracSpan: 0.1)
        built = await seedExactRejections(in: built, exact: exact, t, fracBase: 0.95, fracSpan: 0.05)
        if bailIfCancelled(t) { return }
        groups = built
        exactDupeGroupIDs = exact

        progressFraction = 1.0
        hasScanned = true
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        var doneNotice = groups.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(groups.count)
        if pairedVideoUndetermined > 0 {
            doneNotice += " " + t.scanPairedVideosSkipped(pairedVideoUndetermined)
        }
        scanNotice = doneNotice
        await releaseScanCaches()
        // Unguarded variant: this pipeline's own defer hasn't cleared
        // `isScanning` yet, and `groups` is complete here by construction.
        saveSnapshotIgnoringScanState()
    }

    /// "Similar sets": find sets of photos you took of the same thing — several
    /// near-same shots (like three poses of the same cat) — by clustering the
    /// chosen source on visual similarity (looser than Look-alikes), then naming
    /// each set from its Vision content tags (prettified by apfel if available).
    /// No deletion — this is for browsing/curation.
    func scanSimilarSets(_ t: L10n) async {
        progress = t.progFetching()
        defer { isScanning = false; progress = ""; progressFraction = nil }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        // Bail BEFORE the state wipe (see scan()) — a scan that never ran must
        // leave the previous session's review state untouched.
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            // The defer wipes `progress` on return, so the album-gone message must
            // travel via the one-shot notice or the user never sees why nothing ran.
            scanNotice = t.progAlbumGone()
            return
        }

        await LookAlikeScanner.clearCache()   // pixels may have changed since last scan
        groups = []
        categories = []
        assetsByID = [:]
        facesApplied = false
        displayRotation = [:]   // Pass 2a: rotations don't survive a rescan
        exactDupeGroupIDs = []  // stale exact verdicts never outlive a rescan
        uniqueMetadataWithheld = 0
        uniqueMetadataIDs = []

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a) }
        // FIX 1 — Live Photo paired-video guard (off the main actor; see scan()).
        var pairedVideoUndetermined = 0
        if includeVideo {
            (assets, pairedVideoUndetermined) = await excludeLivePhotoPairedVideos(assets)
        }
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(assets.count)
        for a in assets { map[a.localIdentifier] = a }
        assetsByID = map

        await loadEnrichmentIfNeeded(t, newestFirst: assets)
        if bailIfCancelled(t) { return }
        let enr = enrichment ?? [:]

        // Cluster the library at the "same scene, different moment" band — looser
        // than Look-alikes (which is now ≈identical only), so pose/angle changes
        // still group (cats ≈0.3 feature distance land here, not in Look-alikes).
        let idGroups = await LookAlikeScanner.scan(
            assets: assets, manager: imageManager, t: t,
            dHashDistance: 14, featureDistance: 0.45
        ) { [weak self] msg, frac in
            Task { @MainActor in
                self?.progress = msg
                if let frac { self?.progressFraction = 0.05 + 0.6 * frac }
            }
        }
        if bailIfCancelled(t) { return }

        // Build the qualifying buckets first (cheap, main-actor), THEN name them
        // with bounded concurrency. Each name awaits a Vision classify plus a fresh
        // apfel LLM subprocess (Apple Intelligence), so a serial loop over hundreds
        // of buckets is a long dead tail after all pixel work is done. apfel
        // processes overlap fine — run ~4 in flight while preserving display order.
        struct PendingSet { let photos: [Photo]; let rep: PHAsset? }
        var pending: [PendingSet] = []
        for ids in idGroups {
            if bailIfCancelled(t) { return }
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            guard photos.count >= 2 else { continue }
            pending.append(PendingSet(photos: photos, rep: photos.first.flatMap { map[$0.uuid] }))
        }
        var names = [String?](repeating: nil, count: pending.count)
        let total = pending.count
        let mgr = imageManager
        var done = 0
        await withTaskGroup(of: (Int, String).self) { group in
            var next = 0
            let limit = 4
            let flag = abortFlag
            func add() {
                while !flag.isSet, !Task.isCancelled, next < pending.count {
                    let idx = next; let rep = pending[next].rep; next += 1
                    group.addTask { (idx, await LibraryModel.setName(repAsset: rep, manager: mgr, t: t)) }
                    return
                }
            }
            for _ in 0..<limit { add() }
            for await (idx, name) in group {
                names[idx] = name
                done += 1
                if done % 5 == 0 {
                    progress = t.progNaming(done, total)
                    progressFraction = 0.65 + 0.35 * Double(done) / Double(max(total, 1))
                }
                add()
            }
        }
        if bailIfCancelled(t) { return }
        categories = zip(pending, names)
            .map { CategoryBucket(label: $0.1 ?? t.setFallbackName(), photos: $0.0.photos) }
            .sorted { $0.count > $1.count }

        progressFraction = 1.0
        hasScanned = true
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        var catNotice = categories.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(categories.count)
        if pairedVideoUndetermined > 0 {
            catNotice += " " + t.scanPairedVideosSkipped(pairedVideoUndetermined)
        }
        scanNotice = catNotice
        await releaseScanCaches()
        // Unguarded variant: this pipeline's own defer hasn't cleared
        // `isScanning` yet, and `groups` is complete here by construction.
        saveSnapshotIgnoringScanState()
    }

    /// Name a set from the Vision tags of its representative frame, prettified by
    /// apfel when available; otherwise the top tag (or a localized fallback).
    /// Nonisolated so the naming pass can run these concurrently off the main
    /// actor — the representative asset is resolved by the caller.
    private nonisolated static func setName(repAsset: PHAsset?,
                                            manager: PHCachingImageManager, t: L10n) async -> String {
        guard let repAsset else { return t.setFallbackName() }
        let tags = await CategoryScanner.labels(for: repAsset, manager: manager)
        guard let top = tags.first else { return t.setFallbackName() }
        if let pretty = await Apfel.albumName(tags: tags, language: t.language) { return pretty }
        return CategoryScanner.displayName(top)
    }

    /// Promote a frame to keeper: clear its rejection AND set it as keeper ★.
    /// ⏎ action in grid and loupe.
    func promote(group groupID: ReviewGroup.ID, to photoID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keeperID = photoID
        groups[i].rejected.remove(photoID)   // un-reject the new keeper
        groups[i].autoSeeded.remove(photoID)
        scheduleSnapshotSave()
    }

    /// Keep the entire group — clear all rejections. `a` key.
    func keepAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].rejected = []
        groups[i].autoSeeded = []   // user overrode — rejections are theirs now
        groups[i].includeProtected = false
        scheduleSnapshotSave()
    }

    /// Toggle keep-all: if there are rejections, clear them; if already clear, re-seed.
    func toggleKeepAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[i].rejected.isEmpty {
            // Already keeping all — re-seed. Core `bulkRejectCandidates` is the
            // one composition rule: keeper out, protected out, UNVERIFIABLE out.
            let photos = groups[i].photos
            let keep = photos.first { $0.uuid == groups[i].keeperID } ?? photos[0]
            groups[i].rejected = bulkRejectCandidates(photos: photos, keeperID: keep.uuid)
        } else {
            groups[i].rejected = []
            groups[i].includeProtected = false
        }
        groups[i].autoSeeded = []   // either way this was a user decision
        scheduleSnapshotSave()
    }

    /// Reject whole group: seed rejected = every frame the bulk rule allows.
    /// `d` key. Returns the number of frames it had to LEAVE OUT because they
    /// are unverifiable, so the caller can say so instead of quietly marking
    /// fewer photos than the button promised.
    ///
    /// The button's own words are "Delete every frame in this group (protected
    /// photos stay safe)". Before this, `d` filtered on `!isProtected` only — so
    /// on an Optimize-Mac-Storage library the frames whose originals aren't
    /// local (document eval never ran, `documentEvalDegraded`) went straight
    /// into the delete bucket, unclassified, with the label promising the
    /// opposite. Core `bulkRejectCandidates` is now the single rule.
    @discardableResult
    func rejectAll(group groupID: ReviewGroup.ID) -> Int {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return 0 }
        let photos = groups[i].photos
        let keep = photos.first { $0.uuid == groups[i].keeperID } ?? photos[0]
        groups[i].rejected = bulkRejectCandidates(photos: photos, keeperID: keep.uuid)
        groups[i].autoSeeded = []   // user overrode — rejections are theirs now
        scheduleSnapshotSave()
        return bulkRejectWithheld(photos: photos, keeperID: keep.uuid).count
    }

    /// Toggle reject-all: if not all non-protected are rejected, reject them;
    /// if already fully rejected, clear all rejections (bulk toggle). `d` key via UI.
    func toggleDeleteAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if groups[i].deleteAll {
            // Was fully rejected — clear all.
            groups[i].rejected = []
            groups[i].includeProtected = false
        } else {
            rejectAll(group: groupID)
        }
        scheduleSnapshotSave()
    }

    /// Toggle reject on a single frame. `X` / `⌫` key.
    /// Protected frames: MARKING is a NO-OP (returns false, caller shows hint) —
    /// only the ⇧X/`forceReject` informed-consent path may mark them. UN-marking
    /// is the safe direction and is always allowed, protected or not; a
    /// force-included frame must never be trapped in the delete bucket.
    /// Returns true if the toggle happened, false if blocked (protected frame).
    @discardableResult
    func toggleReject(group groupID: ReviewGroup.ID, frameID: String) -> Bool {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        guard let p = groups[i].photos.first(where: { $0.uuid == frameID }) else { return false }
        if groups[i].rejected.contains(frameID) {
            groups[i].rejected.remove(frameID)
            groups[i].autoSeeded.remove(frameID)   // a later re-reject is the user's call
            // The group-level override must not outlive its last protected
            // rejection — a lingering flag would silently re-arm the next ⇧X.
            if p.isProtected && groups[i].protectedDeletionCount == 0 {
                groups[i].includeProtected = false
            }
        } else {
            if p.isProtected { return false }   // blocked — caller shows hint
            groups[i].rejected.insert(frameID)
            // If rejecting the current keeper, promote to next best.
            if frameID == groups[i].keeperID {
                let remaining = groups[i].photos.filter { !groups[i].rejected.contains($0.uuid) }
                if let next = remaining.max(by: { rankKey($0) < rankKey($1) }) {
                    groups[i].keeperID = next.uuid
                }
            }
        }
        scheduleSnapshotSave()
        return true
    }

    /// Force-reject a protected frame — the ⇧X informed-consent path.
    /// Caller MUST show confirmation dialog before calling this.
    /// Sets includeProtected=true for this group (flags the group needs confirm on commit).
    func forceReject(group groupID: ReviewGroup.ID, frameID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].rejected.insert(frameID)
        groups[i].includeProtected = true   // flag: this group now has protected rejections
        // If rejecting the keeper, re-derive keeper from remaining non-rejected frames.
        if frameID == groups[i].keeperID {
            let remaining = groups[i].photos.filter { !groups[i].rejected.contains($0.uuid) }
            if let next = remaining.max(by: { rankKey($0) < rankKey($1) }) {
                groups[i].keeperID = next.uuid
            }
        }
        scheduleSnapshotSave()
    }

    /// Explicit opt-in to include protected frames in the deletion set for this group.
    /// NEVER called by the scanner; UI-only action that requires prior confirmation.
    func setIncludeProtected(group groupID: ReviewGroup.ID, value: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].includeProtected = value
        let protectedIDs = Set(groups[i].photos.filter { $0.isProtected && !$0.isUnverifiable }.map(\.uuid))
        if value {
            // The opt-in must actually mark the frames: rejectAll/toggle paths
            // always exclude protected frames, so without this insertion the
            // amber "Including protected (N)" state was a lie — deletionIDs
            // stayed unchanged and the N frames were silently kept.
            // KNOWN protections only. An unverifiable frame has no fact to
            // consent to overriding, so the informed-consent path cannot reach
            // it (Core `isEffectiveDeletion` would refuse it anyway — this keeps
            // the marks honest instead of showing marks that never commit).
            groups[i].rejected.formUnion(protectedIDs.subtracting([groups[i].keeperID]))
        } else {
            // Removing override: un-reject all protected frames.
            groups[i].rejected.subtract(protectedIDs)
        }
        groups[i].autoSeeded.subtract(protectedIDs)   // these are user decisions
        scheduleSnapshotSave()
    }

    /// Combined keeper key: an app-level extension of Core's `RankKey` that slots
    /// the on-device face score just below favorite (the frame where people look
    /// their best), then mirrors Core exactly: quality, original-camera,
    /// sharpness, format, size, earliest take. Kept in lockstep with `rankKey` so
    /// the face pass can only re-pick the keeper — never resurrect a deleted
    /// signal or change WHICH frames are deletable.
    private struct FaceRankKey: Comparable {
        let favorite: Int, face: Int, core: RankKey
        static func < (a: FaceRankKey, b: FaceRankKey) -> Bool {
            if a.favorite != b.favorite { return a.favorite < b.favorite }
            if a.face != b.face { return a.face < b.face }
            return a.core < b.core   // quality, original-camera, sharpness, uti, size, take
        }
    }
    private func faceRankKey(_ p: Photo) -> FaceRankKey {
        FaceRankKey(favorite: p.favorite ? 1 : 0,
                    face: Int(((faceScores[p.uuid] ?? 0) * 100).rounded()),
                    core: rankKey(p))
    }

    /// On-device Vision pass: score the faces in every cluster member, then
    /// re-pick each keeper to favour the frame where people look their best.
    /// Bounded to cluster members; favorites stay protected.
    func refineWithFaces(_ t: L10n) async {
        // Mutually exclusive with scans AND deletes: a refine that completes over
        // a newer scan's groups would re-pick keepers from stale face scores and
        // stomp the scan's progress text; one racing a delete re-crowns keepers
        // in groups the delete is about to rewrite.
        guard !refiningFaces, !isScanning, !isDeleting else { return }
        refiningFaces = true
        // Fresh abort flag so a prior cancelled scan/refine can't abort this one;
        // cancelScan() sets it and the loop below drains cooperatively.
        abortFlag = AbortFlag()
        defer { refiningFaces = false }

        let members = Array(Set(groups.flatMap { $0.photos.map(\.uuid) })
            .subtracting(faceScores.keys))
        let total = members.count
        progress = t.progFaces(0, total)
        progressFraction = total > 0 ? 0 : nil
        let lookup = assetsByID
        let mgr = imageManager
        var done = 0
        // Bounded concurrency, matching enrichFlags: FaceScorer.score is a
        // network-allowed per-asset fetch, so a serial loop over thousands of
        // iCloud-evicted cluster members ran for hours. 6-wide overlaps the
        // download/decode latency; a stuck asset can't stall the batch (timeout
        // inside VisionGuards).
        var scores: [String: Double] = [:]
        await withTaskGroup(of: (String, Double).self) { group in
            var next = 0
            let limit = 6
            let flag = abortFlag
            func add() {
                while !flag.isSet, !Task.isCancelled, next < members.count {
                    let id = members[next]; next += 1
                    guard let a = lookup[id] else { continue }
                    group.addTask { (id, await FaceScorer.score(asset: a, manager: mgr)) }
                    return
                }
            }
            for _ in 0..<limit { add() }
            for await (id, score) in group {
                scores[id] = score
                done += 1
                if done % 25 == 0 {
                    progress = t.progFaces(done, total)
                    if total > 0 { progressFraction = Double(done) / Double(total) }
                }
                add()
            }
        }
        // Cache what we computed even on cancel — a re-run resumes on the
        // remaining members (already-scored keys are subtracted at entry).
        for (id, s) in scores { faceScores[id] = s }
        if abortFlag.isSet || Task.isCancelled {
            // Don't re-pick keepers from a partial pass — that would crown frames
            // by incomplete face data. Leave the current keepers untouched.
            progress = ""
            progressFraction = nil
            return
        }
        groups = groups.map { g in
            var ng = g
            ng.keeperID = (g.photos.max { faceRankKey($0) < faceRankKey($1) } ?? g.photos[0]).uuid
            // Same invariant as promote(): the keeper must never stay in the
            // rejection set. Without this, a face-refine after marks are seeded
            // can crown a rejected frame and the group's own keeper gets
            // deleted on commit (while the group vanishes from the sheet).
            ng.rejected.remove(ng.keeperID)
            ng.autoSeeded.remove(ng.keeperID)
            return ng
        }
        facesApplied = true
        progress = ""
        progressFraction = nil
        scheduleSnapshotSave()
    }

    // MARK: - Exact-duplicate detection (Part B)

    /// Run the exact-duplicate predicate over the just-built groups to identify
    /// which ones are genuine identical copies (not just bursts). Runs
    /// automatically at the end of `scan()` and `scanLookAlikes()`, on the
    /// local pipeline array — before anything is published to the UI.
    ///
    /// A group qualifies as exact-duplicate when:
    ///   - No member is a video (a single poster frame is not an identity test), AND
    ///   - All members share the same UTI (a RAW+JPEG / original+re-export pair is
    ///     never interchangeable, even when it looks identical), AND
    ///   - All members share the same pixel dimensions, AND
    ///   - The max pairwise dHash Hamming distance == 0, AND
    ///   - The max pairwise feature-print distance ≤ ExactDuplicatePredicate.featureThreshold, AND
    ///   - The SHA-256 of every member's original file is IDENTICAL. This is the
    ///     final, non-perceptual gate: two flat images (white scans, night shots,
    ///     screenshots) can fool BOTH perceptual gates at once, so a "suggest
    ///     delete" verdict is only ever issued on byte-proven copies. Originals
    ///     that aren't local (iCloud-evicted) are never downloaded for this —
    ///     unverifiable means NOT exact.
    ///
    /// The caller stores the result in `exactDupeGroupIDs` for the UI and
    /// AlbumWriter (a cancelled pass returns the partial set; the caller bails
    /// without publishing).
    func detectExactDuplicates(in snapshot: [ReviewGroup], _ t: L10n,
                               fracBase: Double = 0.9, fracSpan: Double = 0.1) async -> Set<ReviewGroup.ID> {
        guard !snapshot.isEmpty else { return [] }
        progress = t.progVerifying(0, snapshot.count)

        // We need feature prints for the dimension+dHash-consistent groups.
        // Re-use the existing photo hashes via a lightweight second pass.
        // All hashing and print computation runs off the main actor.
        let lookup = assetsByID
        let mgr = imageManager

        var exact: Set<ReviewGroup.ID> = []
        var done = 0
        for g in snapshot {
            if Task.isCancelled || abortFlag.isSet { return exact }   // caller bails + cleans up
            defer {
                done += 1
                if done % 10 == 0 {
                    progress = t.progVerifying(done, snapshot.count)
                    progressFraction = fracBase + fracSpan * Double(done) / Double(snapshot.count)
                }
            }

            // 0+1. Pixel-free eligibility (member count, no videos, single UTI,
            // matching dimensions) — pure Core predicate, unit-tested.
            guard exactGroupPrecheck(g.photos) else { continue }

            // 2. dHash distance == 0 for ALL pairs (computed in Core — no I/O).
            //    We need thumbnails; request them with bounded concurrency.
            let ids = g.photos.map(\.uuid)
            let hashes = await LookAlikeScanner.dHashesPublic(ids, byID: lookup, manager: mgr)
            guard hashes.count == ids.count else { continue }
            let hashValues = ids.compactMap { hashes[$0] }
            guard hashValues.count == ids.count else { continue }
            var allZero = true
            outer: for i in 0..<hashValues.count {
                for j in (i + 1)..<hashValues.count {
                    if hamming(hashValues[i], hashValues[j]) > ExactDuplicatePredicate.hammingThreshold {
                        allZero = false; break outer
                    }
                }
            }
            guard allZero else { continue }

            // 3. Feature-print distance ≤ featureThreshold for ALL pairs.
            let spreads = await LookAlikeScanner.featureSpreads([ids], byID: lookup, manager: mgr) { _, _, _ in }
            guard let spread = spreads.first, let s = spread,
                  s <= ExactDuplicatePredicate.featureThreshold else { continue }

            // 4. Byte verification: every member's original must hash identically.
            //    Any unreadable/evicted original → cannot verify → not exact.
            var digests: Set<String> = []
            var verifiable = true
            for id in ids {
                guard let a = lookup[id],
                      let d = await OriginalHasher.sha256(asset: a) else {
                    verifiable = false
                    break
                }
                digests.insert(d)
            }
            guard verifiable, digests.count == 1 else { continue }

            exact.insert(g.id)
        }

        progress = ""
        return exact
    }

    /// Seed deletion suggestions from the exact-duplicate verdicts — the ONLY
    /// place the app ever pre-marks a frame. For each verified group: reject all
    /// non-keeper, non-protected, non-degraded frames and remember them in
    /// `autoSeeded` so the audit log can attribute them as `.exactDuplicate`.
    /// SLICE-1 INVARIANT: protected frames are NEVER auto-seeded. FIX #4:
    /// degraded-eval frames (iCloud-evicted / timeout) are NEVER auto-seeded.
    ///
    /// LAST GATE: before a candidate is seeded it gets a high-quality document
    /// re-check (`PhotoFlags.isDocumentHiQ`). The browse-time badge runs on
    /// cheap local thumbnails and provably misses documents whose only local
    /// representation is a ~48px micro-thumb — the suggestion path must judge
    /// on real pixels. A confirmed document flips the frame to protected; an
    /// unverifiable one (nil) is simply not seeded. Exact groups are rare, so
    /// the extra fetches cost nothing overall.
    /// Seeds into the LOCAL pipeline array, never the published `groups`: the
    /// hi-q document re-checks suspend for up to 30 s each, and a seeder that
    /// wrote through published state across those awaits could override user
    /// decisions made in the meantime (or trap on indices a mid-scan delete
    /// shifted). The caller publishes the returned array exactly once.
    private func seedExactRejections(in built: [ReviewGroup],
                                     exact: Set<ReviewGroup.ID>, _ t: L10n,
                                     fracBase: Double, fracSpan: Double) async -> [ReviewGroup] {
        guard !exact.isEmpty else { return built }
        var built = built
        // Report progress: the hi-q document re-check below suspends up to 30 s
        // per candidate, so on a big library this tail can run minutes — it must
        // keep the scan's single progress surface alive, not blank out.
        let total = exact.count
        var done = 0
        progress = t.progVerifying(0, total)
        progressFraction = fracBase
        for i in built.indices where exact.contains(built[i].id) {
            if Task.isCancelled || abortFlag.isSet { return built }   // caller bails + cleans up
            defer {
                done += 1
                progress = t.progVerifying(done, total)
                progressFraction = fracBase + fracSpan * Double(done) / Double(total)
            }
            let keeperID = built[i].keeperID
            var seeds: Set<String> = []
            // Byte-identical is an answer about PIXELS. It is not an answer
            // about the LIBRARY ENTRY: the copy we would suggest removing may be
            // the one the user captioned and filed into three albums, and the
            // two thumbnails in the sheet are literally the same image, so they
            // cannot catch it. Compare what each copy carries first; anything
            // the probe cannot determine counts as "carries" (Core
            // `carriesUniqueMetadata`) and the frame is simply not pre-marked —
            // the group keeps its exact badge and stays the user's to decide.
            let metadata = await libraryMetadata(for: built[i].photos.map(\.uuid))
            let keeperMeta = metadata[keeperID] ?? LibraryMetadata()
            for (j, p) in built[i].photos.enumerated() {
                guard p.uuid != keeperID, p.isDeletable else { continue }
                if carriesUniqueMetadata(candidate: metadata[p.uuid] ?? LibraryMetadata(),
                                         keeper: keeperMeta) {
                    uniqueMetadataWithheld += 1
                    // Only badge what we could actually READ: an undetermined
                    // probe justifies withholding the pre-mark, but claiming
                    // "carries a caption" about a frame we couldn't read would
                    // be inventing a fact on the confirmation surface.
                    if (metadata[p.uuid] ?? LibraryMetadata()).isFullyDetermined {
                        uniqueMetadataIDs.insert(p.uuid)
                    }
                    continue
                }
                if let asset = assetsByID[p.uuid] {
                    switch await PhotoFlags.isDocumentHiQ(asset, manager: imageManager) {
                    case .some(true):
                        // Real document — upgrade the frame's flag so the UI
                        // badge and every downstream guard agree.
                        built[i].photos[j] = built[i].photos[j]
                            .with(isDocument: true, documentEvalDegraded: false)
                        continue
                    case .none:
                        continue   // couldn't verify — stay protective, don't seed
                    case .some(false):
                        break      // verified not a document — safe to seed
                    }
                }
                seeds.insert(p.uuid)
            }
            built[i].rejected.formUnion(seeds)
            built[i].autoSeeded = seeds
        }
        return built
    }

    /// Album membership + caption presence for a set of frames.
    ///
    /// Album membership comes from public PhotoKit (`fetchAssetCollections
    /// (containing:)`), the caption/title from the sidecar — and only when that
    /// sidecar is the verified live library, since a stale copy would answer
    /// "no caption" for a caption written last week. Whatever can't be read
    /// stays `nil` = UNDETERMINED; `carriesUniqueMetadata` reads nil as
    /// "carries", so an unreadable probe withholds suggestions instead of
    /// issuing unsafe ones.
    ///
    /// KNOWN GAP, stated rather than papered over: Photos exposes no public API
    /// for KEYWORDS, and this repo has never verified their table layout against
    /// a real library, so keywords are not compared. A keyword-only difference
    /// between two byte-identical copies is therefore still invisible here.
    private func libraryMetadata(for uuids: [String]) async -> [String: LibraryMetadata] {
        guard !uuids.isEmpty else { return [:] }
        var albums: [String: Int] = [:]
        for id in uuids {
            guard let asset = assetsByID[id] else { continue }
            // Through the lane: this is a synchronous PhotoKit call and a wedged
            // photolibraryd must strand one sacrificial thread, never the pool.
            // nil (timeout / breaker) stays nil — undetermined, not zero.
            if let n: Int = await PhotoKitSyncLane.call({
                PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album,
                                                                  options: nil).count
            }) {
                albums[id] = n
            }
        }
        var described: [String: Bool]? = nil
        if libraryIdentity.isVerified {
            let zs = uuids.map { QualitySidecar.zuuid(fromLocalIdentifier: $0) }
            let path = sidecarPath
            if let raw = await Task.detached(priority: .userInitiated, operation: {
                QualitySidecar.userMetadata(zuuids: zs, libraryPath: path)
            }).value {
                var byLocal: [String: Bool] = [:]
                for id in uuids {
                    byLocal[id] = raw[QualitySidecar.zuuid(fromLocalIdentifier: id)] ?? false
                }
                described = byLocal
            }
        }
        var out: [String: LibraryMetadata] = [:]
        for id in uuids {
            out[id] = LibraryMetadata(albumCount: albums[id], hasDescription: described?[id])
        }
        return out
    }

    /// Groups whose surviving keeper no longer resolves in the LIVE library.
    /// Used by the pre-commit sheet so the confirmation surface can say why a
    /// group is being skipped, before the user commits — `commitSweepDecision`
    /// enforces the same rule again at the last moment, because the sheet can
    /// sit open for a long time.
    func missingKeeperGroupIDs() async -> Set<ReviewGroup.ID> {
        var keeperByGroup: [ReviewGroup.ID: String] = [:]
        for g in groups where !g.deletionIDs.isEmpty {
            if let k = survivingKeeper(photos: g.photos, keeperID: g.keeperID,
                                       rejected: g.rejected,
                                       includeProtected: g.includeProtected) {
                keeperByGroup[g.id] = k.uuid
            }
        }
        guard !keeperByGroup.isEmpty else { return [] }
        let ids = Array(Set(keeperByGroup.values))
        let opts = PHFetchOptions()
        opts.includeAllBurstAssets = true
        let found: Set<String> = await Task.detached(priority: .userInitiated) {
            var live: Set<String> = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: opts)
                .enumerateObjects { a, _, _ in live.insert(a.localIdentifier) }
            return live
        }.value
        return Set(keeperByGroup.filter { !found.contains($0.value) }.keys)
    }

    // MARK: - Deletion-intent journal

    /// Reconcile a journal left behind by an interrupted commit. Call once at
    /// launch. Anything it books is verified against the live library first: a
    /// journalled asset that still EXISTS was never deleted (the system
    /// confirmation was cancelled, or the process died before performChanges),
    /// and inventing history is worse than missing it. Publishes a count so the
    /// view can say so — a history that silently repaired itself is still a
    /// history the user had no reason to trust.
    func reconcileDeletionJournal() {
        guard let intent = DeletionAuditLog.pendingIntent() else { return }
        let ids = intent.records.map(\.assetIdentifier)
        var stillExisting: Set<String> = []
        if !ids.isEmpty {
            let opts = PHFetchOptions()
            opts.includeAllBurstAssets = true
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: opts)
                .enumerateObjects { a, _, _ in stillExisting.insert(a.localIdentifier) }
        }
        let logged = DeletionAuditLog.loggedAssetIdentifiers(from: DeletionAuditLog.loadSessions())
        let records = DeletionAuditLog.recoverableRecords(from: intent,
                                                          stillExisting: stillExisting,
                                                          alreadyLogged: logged)
        if !records.isEmpty {
            let recovered = DeletionSession(timestamp: intent.timestamp, records: records)
            if DeletionAuditLog.append(recovered) { journalRecoveredCount = records.count }
        }
        DeletionAuditLog.clearIntent()
    }

    // MARK: - Scan snapshot (cross-launch persistence)

    private func makeSnapshot() -> ScanSnapshot {
        ScanSnapshot(
            schema: ScanSnapshot.currentSchema,
            kind: lastScanKind.rawValue,
            sourceID: {
                if case .album(let item) = scanSource { return item.id }
                return nil
            }(),
            timestamp: Date(),
            // Persist the SCAN's reference token verbatim, never a fresh "now"
            // read — see `scanChangeToken`. A debounced decision-save must not
            // re-bless verdicts against a library that changed since the scan.
            changeToken: scanChangeToken,
            groups: groups.map { g in
                ScanSnapshot.Group(photos: g.photos,
                                   keeperID: g.keeperID,
                                   rejected: Array(g.rejected),
                                   autoSeeded: Array(g.autoSeeded),
                                   confidentDupe: g.confidentDupe,
                                   exact: exactDupeGroupIDs.contains(g.id))
            },
            categories: categories.map { ScanSnapshot.Category(label: $0.label, photos: $0.photos) }
        )
    }

    /// Advance the staleness reference token AFTER one of snapsift's own library
    /// mutations (album membership write, rotation save, delete). If the snapshot
    /// was current going into the write, the ONLY change in the library is ours
    /// and the verdicts remain valid, so we move the reference to the post-write
    /// state — otherwise a relaunch would treat our own write as a verdict-
    /// invalidating external mutation and needlessly drop every exact pre-mark.
    /// If it was already stale, we leave it stale (an external edit still stands).
    private func restampTokenAfterOwnWrite(wasCurrent: Bool, ourIDs: Set<String>) {
        guard wasCurrent, let before = scanChangeToken else { return }
        // ONLY when our write was the only thing that happened. An album write
        // over 121K assets runs for tens of seconds; an edit syncing in from an
        // iPhone during that window used to be stamped over as "ours", and the
        // next launch then skipped the very re-check that exists to catch it.
        guard !externalChangesHappened(since: before, ourIDs: ourIDs) else { return }
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
    }

    /// Did anything OTHER than our own write touch the library since `token`?
    /// Any doubt answers YES: a token we can't decode, an API that refuses the
    /// query, a too-old token — all mean "don't move the staleness anchor",
    /// which costs a rescan prompt and never costs a missed protection.
    private func externalChangesHappened(since tokenData: Data, ourIDs: Set<String>) -> Bool {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: PHPersistentChangeToken.self, from: tokenData) else { return true }
        var inserted: Set<String> = [], updated: Set<String> = [], deleted: Set<String> = []
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            for change in changes {
                guard let details = try? change.changeDetails(for: .asset) else { continue }
                inserted.formUnion(details.insertedLocalIdentifiers)
                updated.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
            }
        } catch {
            return true
        }
        return !ownWriteOnly(inserted: inserted, updated: updated,
                             deleted: deleted, ourIDs: ourIDs)
    }

    /// Persist the current review state immediately (after deletes, album
    /// writes, rotation saves). Writes are serialized through ScanSnapshotStore
    /// (see saveAsync) so a newer snapshot can never be overwritten by an older
    /// one still in flight.
    ///
    /// Refuses to write while a scan is rebuilding `groups`: an async caller
    /// resuming mid-scan (writeAlbums holds an await across performChanges for
    /// tens of seconds; rotation save likewise) would otherwise serialize the
    /// WIPED state over last-scan.json — the sole store of the user's review
    /// decisions — and a subsequent cancel/crash would restore nothing. The
    /// scan pipelines persist their own completed state via the unguarded
    /// variant below (their `defer` hasn't cleared `isScanning` yet at that
    /// point). Skipping is safe for every guarded caller: the scan that
    /// preempted them ends with its own fresh save.
    func saveSnapshotNow() {
        guard !isScanning else { return }
        saveSnapshotIgnoringScanState()
    }

    /// Unguarded write for the scan pipelines' natural end, where `groups` is
    /// fully rebuilt but `isScanning` is still true. Everyone else goes through
    /// `saveSnapshotNow()`.
    private func saveSnapshotIgnoringScanState() {
        guard hasScanned else { return }
        snapshotSaveTask?.cancel()
        lastSnapshotWrite = Date()
        let snap = makeSnapshot()
        // The inner Task must close over an immutable LOCAL, not over the outer
        // closure's captured `self`: referencing the capture directly from the
        // concurrently-executing Task is "reference to captured var 'self' in
        // concurrently-executing code" under Swift 5.10 (the CI toolchain), and
        // moving `[weak self]` onto the Task instead just trades that for an
        // implicit strong capture in the outer closure. One `let` settles both.
        ScanSnapshotStore.saveAsync(snap) { [weak self] ok in
            let model = self
            Task { @MainActor in model?.noteSnapshotWrite(succeeded: ok) }
        }
    }

    /// Synchronous flush for app termination: the debounced/async save can't be
    /// relied on to finish as the process exits, so ⌘Q inside the debounce window
    /// would otherwise drop the tail of the session. Writes on the calling actor so
    /// it completes before the app dies.
    func flushSnapshotSync() {
        // Not during a delete either: `groups` still shows the pre-delete marks
        // while performChanges runs, so a ⌘Q flush would persist a snapshot
        // claiming photos exist (and are marked) that Photos just removed.
        // `deleteReviewed` writes its own fresh snapshot when it finishes.
        guard hasScanned, !isScanning, !isDeleting else { return }
        snapshotSaveTask?.cancel()
        ScanSnapshotStore.saveSync(makeSnapshot())
    }

    /// Record a save outcome. On failure, raise a one-shot disk-full notice (the
    /// view localizes and banners it) so the user can free space before quitting;
    /// on success, clear the latch so a later relapse re-notifies.
    private func noteSnapshotWrite(succeeded: Bool) {
        if succeeded {
            snapshotWriteFailedNotified = false
        } else if !snapshotWriteFailedNotified {
            snapshotWriteFailedNotified = true
            snapshotSaveFailedNotice = true
        }
    }

    /// Persist after a decision change, debounced so a burst of keystrokes
    /// (x x x j x…) writes once, not per key.
    func scheduleSnapshotSave() {
        guard hasScanned, !isScanning else { return }
        // Max-deferral cap: a keystroke cadence faster than the debounce interval
        // re-arms the timer on every key and would defer persistence indefinitely.
        // Once enough time has passed since the last save, force one now regardless
        // of the ongoing burst so a long uninterrupted run can't go unpersisted.
        if Date().timeIntervalSince(lastSnapshotWrite) > 15 {
            saveSnapshotNow()
            return
        }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            // Re-check at fire time: if a scan started inside the debounce
            // window, `groups` is already wiped — persisting now would destroy
            // the previous snapshot. Same for a delete: mid-performChanges the
            // groups still show pre-delete marks for photos Photos is removing;
            // deleteReviewed writes its own fresh snapshot when it finishes.
            guard self?.isScanning == false, self?.isDeleting == false else { return }
            self?.saveSnapshotNow()
        }
    }

    /// Rehydrate the last scan (groups + categories + decisions) from disk.
    /// Assets are re-fetched; anything unresolvable is dropped and a group that
    /// falls under 2 frames dissolves. Returns true when something was restored.
    @discardableResult
    /// Live `edited` state for specific frames, re-checked AFTER the scan (the
    /// commit-time protection sweep and the stale-snapshot restore both exist
    /// to catch edits made since). Primary: one targeted Photos.sqlite query,
    /// opened WAL-aware so a minutes-old edit is visible (see
    /// `QualitySidecar.editedFlags`). Fallback (no Full Disk Access): per-asset
    /// PhotoKit through the wedge-proof sacrificial thread — NEVER the raw
    /// synchronous call, which wedged a scan for >24 h when photolibraryd
    /// restarted mid-flight. Returns only the frames it could determine;
    /// callers keep the stored value for the rest.
    private func currentEditedFlags(for targets: [(uuid: String, asset: PHAsset)]) async -> [String: Bool] {
        guard !targets.isEmpty else { return [:] }
        let zuuidByLocal = Dictionary(uniqueKeysWithValues: targets.map {
            ($0.uuid, QualitySidecar.zuuid(fromLocalIdentifier: $0.uuid))
        })
        let zuuids = Array(Set(zuuidByLocal.values))
        // Same gate as the scan: a sidecar we could not prove belongs to the
        // library PhotoKit serves is not evidence about THIS photo's edits.
        let path = sidecarPath
        let sidecar: [String: Bool]? = libraryIdentity.isVerified
            ? await Task.detached(priority: .userInitiated) {
                QualitySidecar.editedFlags(zuuids: zuuids, libraryPath: path)
              }.value
            : nil
        if let sidecar {
            var out: [String: Bool] = [:]
            for (local, z) in zuuidByLocal {
                if let e = sidecar[z] { out[local] = e }
            }
            return out
        }
        var out: [String: Bool] = [:]
        for t in targets {
            if let e = await PhotoFlags.editedFallback(t.asset) { out[t.uuid] = e }
        }
        return out
    }

    func restoreSnapshot(_ t: L10n, quiet: Bool = false) async -> Bool {
        guard !isScanning, groups.isEmpty, categories.isEmpty else { return false }

        // Load + JSON-decode the snapshot and resolve every asset OFF the main
        // actor: a whole-library snapshot is multi-MB JSON and
        // fetchAssets(withLocalIdentifiers:) over tens of thousands of IDs blocks
        // for seconds — on .onAppear that beachballed every launch.
        enum RestoreLoad { case none, unreadable, ok(ScanSnapshot, [String: PHAsset]) }
        let loaded: RestoreLoad = await Task.detached(priority: .userInitiated) {
            switch ScanSnapshotStore.loadOutcome() {
            case .none: return .none
            case .unreadable: return .unreadable
            case .ok(let snap):
                let allIDs = Set(snap.groups.flatMap { $0.photos.map(\.uuid) }
                    + snap.categories.flatMap { $0.photos.map(\.uuid) })
                guard !allIDs.isEmpty else { return .none }
                // Must match the scan fetch: without includeAllBurstAssets the burst
                // sub-frames don't resolve and their groups silently dissolve on
                // restore (live-observed: 2755 → 2632 groups).
                let fetchOpts = PHFetchOptions()
                fetchOpts.includeAllBurstAssets = true
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(allIDs), options: fetchOpts)
                var map: [String: PHAsset] = [:]
                map.reserveCapacity(fetched.count)
                fetched.enumerateObjects { a, _, _ in map[a.localIdentifier] = a }
                return .ok(snap, map)
            }
        }.value
        // A corrupt session file must never masquerade as "nothing to restore"
        // (that reads as silent loss of every review decision — because it is);
        // the store moved the bytes aside for post-mortem, the banner says so.
        if case .unreadable = loaded {
            snapshotUnreadableNotice = true
            return false
        }
        guard case .ok(let snap, let map) = loaded else { return false }
        // RE-CHECK the entry guards after the await gap: a scan (or another
        // restore) started meanwhile must win over this now-stale snapshot rather
        // than be clobbered by it.
        guard !isScanning, groups.isEmpty, categories.isEmpty else { return false }

        // A stale change token means the library was mutated after the scan —
        // scan-time verdicts (byte-verified exact, protection flags) can no
        // longer be trusted for DELETION. The user's own marks are theirs to
        // keep, but every APP-seeded suggestion is dropped and the exact
        // badges are cleared; a rescan re-proves them. Doctrine: pre-marks may
        // only exist while their byte-verified verdict is known-current.
        let tokenCurrent = ScanSnapshotStore.changeTokenIsCurrent(snap.changeToken)

        // Refresh the cheap live flags from the re-fetched assets: a photo
        // favorited OR edited since the scan must be protected NOW, not as of
        // the snapshot (isFavorite is a prefetched property; `edited` is one
        // batched sidecar query — see currentEditedFlags) — only isDocument
        // (Vision, pixels) still needs a rescan. When the token is stale we
        // re-check `edited` for the frames the user REJECTED, so a frame
        // edited after being rejected re-protects itself instead of surviving
        // inside the delete bucket.
        var editedNowByID: [String: Bool] = [:]
        if !tokenCurrent {
            let recheckTargets: [(uuid: String, asset: PHAsset)] = snap.groups.flatMap { gs in
                let rejectedSet = Set(gs.rejected)
                return gs.photos.compactMap { p -> (uuid: String, asset: PHAsset)? in
                    guard rejectedSet.contains(p.uuid), !p.edited,
                          let asset = map[p.uuid] else { return nil }
                    return (p.uuid, asset)
                }
            }
            editedNowByID = await currentEditedFlags(for: recheckTargets)
            // Same rule as after the snapshot load: a scan that started during
            // the await gap wins over this now-stale restore.
            guard !isScanning, groups.isEmpty, categories.isEmpty else { return false }
        }

        var restoredGroups: [ReviewGroup] = []
        var exactIDs: Set<ReviewGroup.ID> = []
        // Count app-seeded suggestions dropped by the stale demotion so the UI can
        // stand up a persistent notice (a launch banner alone would fade unseen).
        var staleClearedSeeds = 0
        // Marks whose PHOTO no longer exists. They were silently compacted away
        // before: a user who marked 300 frames yesterday and lost 40 of them to
        // an external delete saw "restored N groups" and no hint that part of
        // their review work is gone. Counted here, surfaced by the view.
        var vanishedMarks = 0
        for gs in snap.groups {
            let liveIDs = Set(gs.photos.map(\.uuid).filter { map[$0] != nil })
            vanishedMarks += Set(gs.rejected).subtracting(liveIDs).count
            let photos: [Photo] = gs.photos.compactMap { p in
                guard let asset = map[p.uuid] else { return nil }
                let favNow = asset.isFavorite
                let editedNow = editedNowByID[p.uuid] ?? p.edited
                guard favNow != p.favorite || editedNow != p.edited else { return p }
                return p.with(favorite: favNow, edited: editedNow)
            }
            guard photos.count >= 2 else { continue }
            let keeperID = photos.contains { $0.uuid == gs.keeperID }
                ? gs.keeperID : keeper(photos).uuid
            var g = ReviewGroup(photos: photos, keeperID: keeperID)
            let alive = Set(photos.map(\.uuid))
            let protected = Set(photos.filter(\.isProtected).map(\.uuid))
            g.rejected = Set(gs.rejected).intersection(alive)
                .subtracting([keeperID])
                .subtracting(protected)   // protection re-applies on restore
            g.autoSeeded = Set(gs.autoSeeded).intersection(g.rejected)
            if !tokenCurrent {
                staleClearedSeeds += g.autoSeeded.count
                g.rejected.subtract(g.autoSeeded)   // stale app suggestions die
                g.autoSeeded = []
            }
            g.confidentDupe = gs.confidentDupe
            // includeProtected deliberately not restored (informed-consent flag).
            if gs.exact && tokenCurrent { exactIDs.insert(g.id) }
            restoredGroups.append(g)
        }
        let restoredCats = snap.categories.compactMap { cs -> CategoryBucket? in
            let photos = cs.photos.filter { map[$0.uuid] != nil }
            return photos.count >= 2 ? CategoryBucket(label: cs.label, photos: photos) : nil
        }
        guard !restoredGroups.isEmpty || !restoredCats.isEmpty else { return false }

        assetsByID = map
        groups = restoredGroups
        exactDupeGroupIDs = exactIDs
        categories = restoredCats
        hasScanned = true
        // Rehydrate the scan kind so a later makeSnapshot round-trips it and the
        // stale-restore bar's Rescan re-runs the same kind of scan.
        if let kind = ScanKind(rawValue: snap.kind) { lastScanKind = kind }
        // Standing notice: a stale token silently stripped every app-seeded
        // suggestion above — surface how many so the user isn't left wondering
        // where yesterday's pre-marks went (nil = nothing dropped).
        staleRestoreClearedCount = (!tokenCurrent && staleClearedSeeds > 0) ? staleClearedSeeds : nil
        vanishedMarkCount = vanishedMarks > 0 ? vanishedMarks : nil
        // Carry the ORIGINAL reference token forward so post-restore decision
        // saves preserve the scan's staleness anchor (not "now").
        scanChangeToken = snap.changeToken
        // The snapshot's photos carry the sidecar enrichment from scan time, so
        // quality-based ranking (and the size estimate) is genuinely available —
        // don't show the Full Disk Access hint for a restored session.
        qualityAvailable = restoredGroups.contains { g in
            g.photos.contains { $0.quality > 0 || $0.size > 0 }
        }
        // Point the source picker back at what this snapshot actually scanned
        // (if that album still exists) so a rescan hits the same scope.
        if let sourceID = snap.sourceID {
            if let item = albums.first(where: { $0.id == sourceID }) {
                scanSource = .album(item)
            }
        } else {
            scanSource = .wholeLibrary
        }
        if !quiet {
            scanNotice = ScanSnapshotStore.changeTokenIsCurrent(snap.changeToken)
                ? t.snapshotRestored(restoredGroups.isEmpty ? restoredCats.count : restoredGroups.count)
                : t.snapshotRestoredStale()
        }
        return true
    }

    // MARK: - Album write (Part A + Part B)

    /// Sort the scan result into Photos albums — strictly non-destructive
    /// (membership tags only; originals stay in place).
    ///
    /// Part A: bursts, blurry, and documents albums are always review-only.
    ///         Protected frames never appear in any delete-oriented bucket.
    /// Part B: the exact-duplicates album is the ONLY one where non-keeper,
    ///         non-protected frames earn a "suggest delete" badge in the UI.
    ///
    /// Returns a human-readable banner summarising what was written (or
    /// "nothing new" if all assets were already in the albums).
    @discardableResult
    func writeAlbums(_ t: L10n) async throws -> String {
        // Return a fully formed banner ("Sorted into albums · nothing new to add")
        // rather than the bare fragment, which reads as an uncapitalized floater.
        guard !isWritingAlbums, !isDeleting, !groups.isEmpty else {
            return t.albumsWritten(bursts: 0, blurry: 0, docs: 0, exact: 0)
        }
        isWritingAlbums = true
        progress = t.progWritingAlbums()
        defer { isWritingAlbums = false; progress = "" }

        let wasCurrent = ScanSnapshotStore.changeTokenIsCurrent(scanChangeToken)
        let result = try await AlbumWriter.write(
            groups: groups,
            exactGroups: exactDupeGroupIDs,
            assetsByID: assetsByID,
            t: t
        )
        // A membership-only album write mutates no verdict-relevant state, but it
        // DOES advance the library change token. Move the reference forward (and
        // persist) so this recommended review step doesn't silently strand every
        // byte-verified exact pre-mark behind a "library changed" stale restore.
        restampTokenAfterOwnWrite(wasCurrent: wasCurrent,
                                  ourIDs: Set(groups.flatMap { $0.photos.map(\.uuid) }))
        saveSnapshotNow()
        return t.albumsWritten(bursts: result.bursts, blurry: result.blurry,
                               docs: result.documents, exact: result.exactDupes)
    }

    /// Delete every reviewed non-keeper, non-favorite frame via PhotoKit. macOS
    /// shows its own confirmation; items land in Recently Deleted (30 days).
    /// Returns the number actually removed.
    ///
    /// FIX 3 — stale-asset guard: if the library changed since the last scan,
    /// some asset IDs may no longer resolve. Rather than silently dropping them
    /// (which would undercount "Deleted N" and clear groups as if they were gone),
    /// we surface a clear warning and let the caller decide whether to proceed.
    ///
    /// `staleWarning`: non-nil when some IDs could not be resolved. The closure
    /// receives (staleCount, foundCount) and must return `true` to proceed with
    /// the assets that WERE found, or `false` to abort entirely.
    @discardableResult
    func deleteReviewed(
        staleWarning: ((Int, Int) async -> Bool)? = nil,
        onProtectedDropped: ((Int) -> Void)? = nil,
        onBurstSkipped: ((Int) -> Void)? = nil,
        onUndeterminedSkipped: ((Int) -> Void)? = nil,
        onKeeperMissing: ((Int) -> Void)? = nil
    ) async throws -> Int {
        // Never commit while a scan or face-refine is rebuilding group state:
        // a delete would race the pipeline over `groups` and persist a
        // half-built snapshot over the previous complete one. And never
        // re-enter: a second confirm racing the first would double-book the
        // audit log and delete against indices the first is rewriting.
        // isWritingAlbums: symmetric with writeAlbums' own !isDeleting guard —
        // the two commits both mutate the library and must never interleave.
        //
        // THROWS rather than returning 0: "blocked, nothing happened" and
        // "nothing was marked" used to share one exit code, so confirming a
        // delete during an album write showed no banner, no alert and every mark
        // still in place — indistinguishable from a successful delete of zero.
        guard !isScanning, !refiningFaces, !isDeleting, !isWritingAlbums else {
            throw CommitError.busy
        }
        isDeleting = true
        defer { isDeleting = false }

        let states = groups.indices.map { i in
            CommitGroupState(index: i, photos: groups[i].photos, keeperID: groups[i].keeperID,
                             rejected: groups[i].rejected,
                             includeProtected: groups[i].includeProtected)
        }
        let candidateIDs = states.flatMap { st in
            st.photos.filter {
                isEffectiveDeletion($0, rejected: st.rejected, includeProtected: st.includeProtected)
            }.map(\.uuid)
        }
        guard !candidateIDs.isEmpty else { return 0 }

        // Resolve from a LIVE fetch, never the scan-time `assetsByID` snapshot.
        // Three reasons: (1) an asset deleted OUTSIDE snapsift (Photos.app on
        // this Mac, another iCloud device) after the scan still resolves in the
        // stale map and would sail past the FIX 3 guard into performChanges;
        // (2) the protection sweep below must read the CURRENT favorite/edited
        // state, which a stale PHAsset can't provide; (3) — and this is why the
        // fetch covers KEEPERS too, not just deletion candidates — the photo a
        // group promises to KEEP can have been deleted in that same window. It
        // is in fact the likeliest one to be: "two identical shots, I'll bin
        // one" on an iPhone hits the frame snapsift nominated as keeper half the
        // time. Committing that group anyway removes the last surviving copy
        // while the sheet says KEEP and the audit log records a keeper that no
        // longer exists. `commitSweepDecision` withdraws such a group whole.
        // Must match the scan/restore fetch: without includeAllBurstAssets the
        // burst sub-frames don't resolve by identifier and would be misread as
        // externally deleted (same gotcha restoreSnapshot documents).
        let keeperIDs = states.compactMap { st -> String? in
            guard st.photos.contains(where: {
                isEffectiveDeletion($0, rejected: st.rejected, includeProtected: st.includeProtected)
            }) else { return nil }
            return survivingKeeper(photos: st.photos, keeperID: st.keeperID,
                                   rejected: st.rejected,
                                   includeProtected: st.includeProtected)?.uuid
        }
        let fetchIDs = Array(Set(candidateIDs).union(keeperIDs))
        let liveOpts = PHFetchOptions()
        liveOpts.includeAllBurstAssets = true
        let liveFetch = PHAsset.fetchAssets(withLocalIdentifiers: fetchIDs, options: liveOpts)
        var live: [String: PHAsset] = [:]
        live.reserveCapacity(liveFetch.count)
        liveFetch.enumerateObjects { a, _, _ in live[a.localIdentifier] = a }

        // Commit-time protection sweep: a frame favorited or edited SINCE the
        // scan is protected NOW — the same doctrine `restoreSnapshot` applies
        // across launches, enforced here for the live in-session window (hours
        // long on a big library, exactly when a user flips to Photos.app and
        // stars/edits). `favorite` is a free prefetched property; `edited` is
        // one batched WAL-aware sidecar query (see currentEditedFlags — never
        // the raw sync PhotoKit call, which can wedge forever). `isDocument`
        // (Vision/pixels) stays rescan-only. Swept in EVERY group, including
        // includeProtected ones: that per-group consent covered the frames the
        // user SAW as protected in the sheet — a frame that became protected
        // only after the scan was never part of it.
        let sweepTargets: [(uuid: String, asset: PHAsset)] = states.flatMap { st in
            st.photos.compactMap { p -> (uuid: String, asset: PHAsset)? in
                guard isEffectiveDeletion(p, rejected: st.rejected,
                                          includeProtected: st.includeProtected),
                      !p.isProtected, let asset = live[p.uuid] else { return nil }
                return (p.uuid, asset)
            }
        }
        let editedNow = sweepTargets.isEmpty ? [:] : await currentEditedFlags(for: sweepTargets)
        var favoriteNow: [String: Bool] = [:]
        for (uuid, asset) in sweepTargets { favoriteNow[uuid] = asset.isFavorite }

        let decision = commitSweepDecision(
            groups: states,
            live: LiveCommitFacts(resolved: Set(live.keys),
                                  favoriteNow: favoriteNow,
                                  editedNow: editedNow))

        // Apply the verdict to the model.
        var flagsChanged = false
        for frame in decision.swept {
            guard let j = groups[frame.groupIndex].photos
                .firstIndex(where: { $0.uuid == frame.uuid }) else { continue }
            switch frame.reason {
            case .newlyProtected:
                // Real new protection — upgrade the stored flags so the UI and
                // every later guard agree, and clear the mark for good.
                groups[frame.groupIndex].photos[j] = groups[frame.groupIndex].photos[j]
                    .with(favorite: frame.favorite, edited: frame.edited)
                groups[frame.groupIndex].rejected.remove(frame.uuid)
                groups[frame.groupIndex].autoSeeded.remove(frame.uuid)
                flagsChanged = true
            case .undetermined:
                // Cannot verify ⇒ cannot delete. UN-MARK it (b09780f's rule) and
                // record the uncertainty on the frame, so the gallery shows a
                // degraded-protection chip instead of leaving a mark sitting
                // there that no commit will ever honour and no surface explains.
                groups[frame.groupIndex].photos[j] = groups[frame.groupIndex].photos[j]
                    .with(editedUndetermined: true)
                groups[frame.groupIndex].rejected.remove(frame.uuid)
                groups[frame.groupIndex].autoSeeded.remove(frame.uuid)
                flagsChanged = true
            case .vanished:
                break   // the mark stays; the stale-asset warning below owns this
            }
        }
        if decision.newlyProtectedCount > 0 { onProtectedDropped?(decision.newlyProtectedCount) }
        if decision.undeterminedCount > 0 { onUndeterminedSkipped?(decision.undeterminedCount) }
        if !decision.withdrawnGroupIndexes.isEmpty {
            onKeeperMissing?(decision.withdrawnGroupIndexes.count)
        }

        let ids = decision.deleteIDs
        guard !ids.isEmpty else {
            if flagsChanged { saveSnapshotNow() }
            return 0
        }

        var assets = ids.compactMap { live[$0] }
        guard !assets.isEmpty else {
            if flagsChanged { saveSnapshotNow() }
            return 0
        }

        // FIX 3: some marked assets no longer exist (removed outside snapsift
        // since the scan). They are already out of `ids` — the sweep counted
        // them — but the user still gets to decide whether to proceed.
        if decision.vanishedCount > 0 {
            if let warn = staleWarning {
                let proceed = await warn(decision.vanishedCount, assets.count)
                guard proceed else { return 0 }
            }
            // No warning handler supplied: proceed silently with found assets
            // (legacy callers that don't pass the closure get existing behavior).
        }

        // Burst-stack guard: deleting a burst REPRESENTATIVE can be stack-scoped in
        // PhotoKit and take unreviewed sub-frames with it — frames the pre-commit
        // sheet never displayed. Only delete a representative when EVERY frame in
        // its burst is also in this deletion (whole-stack removal is then the
        // user's explicit intent). Otherwise skip it and tell the user to handle
        // that burst in Photos, so the confirmation sheet can never under-report.
        var burstSkipped: Set<String> = []
        if assets.contains(where: { $0.representsBurst }) {
            let deletionSet = Set(ids)
            let bopts = PHFetchOptions()
            bopts.includeAllBurstAssets = true
            for a in assets where a.representsBurst {
                guard let bid = a.burstIdentifier else { continue }
                let siblings = PHAsset.fetchAssets(withBurstIdentifier: bid, options: bopts)
                var allMarked = true
                siblings.enumerateObjects { s, _, stop in
                    if !deletionSet.contains(s.localIdentifier) { allMarked = false; stop.pointee = true }
                }
                if !allMarked { burstSkipped.insert(a.localIdentifier) }
            }
        }
        if !burstSkipped.isEmpty {
            assets = assets.filter { !burstSkipped.contains($0.localIdentifier) }
            onBurstSkipped?(burstSkipped.count)
            guard !assets.isEmpty else { saveSnapshotNow(); return 0 }
        }

        // Build audit records BEFORE the delete (photos still exist in model).
        // Only for IDs that actually RESOLVED and were not burst-skipped: those
        // never reach PHAssetChangeRequest, and the accountability log must never
        // book a deletion snapsift didn't perform.
        let resolvable = Set(assets.map(\.localIdentifier))
        let timestamp = DeletionAuditLog.nowTimestamp()
        var auditRecords: [DeletionRecord] = []
        for g in groups {
            let deletionIDs = g.deletionIDs.filter { resolvable.contains($0) }
            guard !deletionIDs.isEmpty else { continue }
            // No-survivor group (user force-rejected every frame, keeper included):
            // g.keeperID still points at a frame that is itself being deleted, so
            // naming it as "the keeper that survived" would be a lie the 30-day
            // recovery audit relies on. Write the empty-keeper sentinel instead.
            let keeperDeleted = deletionIDs.contains(g.keeperID)
            let keeperPhoto = keeperDeleted ? nil : g.photos.first { $0.uuid == g.keeperID }
            let keeperID = keeperDeleted ? "" : g.keeperID
            let keeperFilename = keeperPhoto?.filename ?? ""
            for deletedID in deletionIDs {
                guard let p = g.photos.first(where: { $0.uuid == deletedID }) else { continue }
                let reason = DeletionAuditLog.reason(
                    for: p, includeProtectedActive: g.includeProtected,
                    autoSeededExact: g.autoSeeded.contains(deletedID)
                )
                auditRecords.append(DeletionRecord(
                    timestamp: timestamp,
                    assetIdentifier: p.uuid,
                    filename: p.filename,
                    sizeBytes: p.size,
                    keeperIdentifier: keeperID,
                    keeperFilename: keeperFilename,
                    reason: reason
                ))
            }
        }

        // Snapshot the staleness anchor state BEFORE our own mutation so we can
        // decide whether to advance it afterward (see restampTokenAfterOwnWrite).
        let tokenWasCurrent = ScanSnapshotStore.changeTokenIsCurrent(scanChangeToken)

        // INTENT JOURNAL — written before the destructive call, cleared after
        // the history write. The window it covers: performChanges succeeds, then
        // the process dies (memory pressure on a thousand-photo commit, or an
        // impatient ⌘Q on what looks like a hang) before the audit append runs.
        // Recently Deleted then holds photos the Deletion History has never
        // heard of, and the next launch drops their marks as "no longer
        // resolvable" — the user's only way to notice is to count by hand.
        // `reconcileDeletionJournal` picks this up at the next launch and
        // VERIFIES each record against the live library before booking it.
        let session = DeletionSession(timestamp: timestamp, records: auditRecords)
        if !auditRecords.isEmpty { DeletionAuditLog.writeIntent(session) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            // Nothing was deleted (performChanges is atomic), so the intent is
            // a lie the next launch must not find.
            DeletionAuditLog.clearIntent()
            throw error
        }

        // Append audit log (best-effort, never aborts the deletion). A write
        // failure (e.g. full disk) still commits the delete, but the accountability
        // record is missing — flag it so the completion banner says so honestly.
        lastDeleteAuditFailed = false
        if !auditRecords.isEmpty {
            lastDeleteAuditFailed = !DeletionAuditLog.append(session)
        }
        // Only once the history carries it (or we know it never will) is the
        // journal's job done.
        DeletionAuditLog.clearIntent()

        // Drop deleted frames; a group that loses all but its keeper is resolved.
        // Crucially, carry the user's review decisions forward: a "keep all" or
        // "delete all" group, or a group the scan flagged as not-confident, must
        // keep that state. Rebuilding with defaults silently re-marks protected
        // photos for deletion on the next pass — an accuracy/trust red line.
        // Burst-skipped representatives were NOT deleted, so they must stay in
        // their groups (still marked, so the user is reminded to handle them).
        let removed = Set(ids).subtracting(burstSkipped)
        var survivingExactIDs: Set<ReviewGroup.ID> = []
        groups = groups.compactMap { g -> ReviewGroup? in
            guard let r = regroupAfterDeletion(photos: g.photos,
                                               keeperID: g.keeperID,
                                               removed: removed) else { return nil }
            var ng = ReviewGroup(photos: r.photos, keeperID: r.keeperID)
            ng.confidentDupe = g.confidentDupe
            // Carry forward only the rejections that still exist in the remaining photos.
            ng.rejected = g.rejected.filter { id in r.photos.contains { $0.uuid == id } }
            ng.autoSeeded = g.autoSeeded.intersection(ng.rejected)
            // includeProtected is intentionally NOT carried forward: after a delete
            // pass the protected frames that were opted-in are already gone, and the
            // remaining group should start fresh (default = protected, as always).
            ng.includeProtected = false
            // Rebuilt groups mint fresh UUIDs — remap the exact-duplicate
            // verdicts or every surviving byte-verified group silently loses
            // its badge, album routing, and persisted exact flag.
            if exactDupeGroupIDs.contains(g.id) { survivingExactIDs.insert(ng.id) }
            return ng
        }
        exactDupeGroupIDs = survivingExactIDs

        // FIX #5 — refresh assetsByID after a successful delete.
        //
        // After the delete pass the assetsByID map still holds the pre-delete
        // snapshot: any asset that was removed is still in the map (stale), and if
        // the library was mutated by another process between the scan and now there
        // may be IDs in the map that no longer exist. We do a cheap metadata-only
        // re-fetch of all IDs that SURVIVED into the remaining groups and rebuild
        // the map from what actually exists. No pixel/image request; no network.
        //
        // Defensive: any surviving group member whose asset no longer resolves is
        // dropped from the group (the group may then resolve to <2 frames and be
        // removed on the next user-facing rescan — we don't compact further here
        // to avoid introducing a second silent mutation).
        let survivingIDs = Set(groups.flatMap { $0.photos.map(\.uuid) })
        if !survivingIDs.isEmpty {
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(survivingIDs), options: nil)
            var freshMap: [String: PHAsset] = [:]
            freshMap.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                freshMap[asset.localIdentifier] = asset
            }
            assetsByID = freshMap
        } else {
            assetsByID = [:]
        }

        // Our own delete advanced the library token; move the staleness anchor
        // forward (only when it was current going in) so a relaunch doesn't treat
        // this commit as an external mutation and discard surviving exact marks.
        restampTokenAfterOwnWrite(wasCurrent: tokenWasCurrent, ourIDs: Set(removed))

        // Keep the cross-launch snapshot in lockstep — a relaunch must never
        // resurrect frames that were just deleted.
        saveSnapshotNow()

        return assets.count
    }
}
