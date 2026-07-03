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
        let nonKeeperNonProtected = photos.filter { $0.uuid != keeperID && !$0.isProtected }
        guard !nonKeeperNonProtected.isEmpty else { return false }
        return nonKeeperNonProtected.allSatisfy { rejected.contains($0.uuid) }
    }

    func isKeeper(_ p: Photo) -> Bool { p.uuid == keeperID && !rejected.contains(p.uuid) }
    func isDelete(_ p: Photo) -> Bool {
        guard rejected.contains(p.uuid) else { return false }
        // Protected frames only deletable when explicitly opted in.
        if p.isProtected && !includeProtected { return false }
        return true
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
    @Published var progress = ""
    @Published var includeVideo = false
    /// True once Apple's quality scores have been read from the library sidecar.
    @Published var qualityAvailable = false
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
    private var lastScanKind: ScanKind = .burst
    private var snapshotSaveTask: Task<Void, Never>?

    /// Launch a scan as a cancellable task. UI entry point for all three kinds.
    /// A running face-refine mutates keepers concurrently, so the two pipelines
    /// are mutually exclusive here (and again in `refineWithFaces`).
    func startScan(_ kind: ScanKind, _ t: L10n) {
        guard !isScanning, !refiningFaces else { return }
        // Set synchronously — the scan method body runs in a separately-enqueued
        // task, and a guard that only trips once the body executes lets a second
        // startScan in the same runloop turn clobber scanTask/abortFlag (Cancel
        // would then cancel the wrong task).
        isScanning = true
        // A debounced decision-save must never fire after the scan wipes
        // `groups` — it would atomically replace the snapshot (thousands of
        // review decisions) with an empty one.
        snapshotSaveTask?.cancel()
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

    /// Cancel the in-flight scan. The pipeline drains cooperatively; the scan
    /// method notices the cancellation and calls `finishCancelledScan`.
    func cancelScan() {
        guard isScanning else { return }
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
        restoreSnapshot(t, quiet: true)
        scanNotice = t.scanCancelled()
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
    // Saving marks the photo as edited (PHAdjustmentData present), so
    // PhotoFlags.edited() will return true and snapsift will then treat the
    // frame as a protected frame. This is expected and is disclosed in the
    // confirmation dialog.

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
            restampTokenAfterOwnWrite(wasCurrent: wasCurrent)
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

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            // FIX 1 — Live Photo paired-video guard.
            // When includeVideo is true, the .mov companion of a Live Photo appears
            // as an independent video PHAsset. Deleting it orphans the Live Photo
            // still (motion is permanently lost and the pair is NOT recoverable as
            // a pair from Recently Deleted). We exclude it here.
            //
            // Detection: PHAssetResource.assetResources(for:) is synchronous and
            // returns the resource descriptors for an asset without touching pixels.
            // A Live Photo paired video has at least one resource with type
            // .pairedVideo (9) or .fullSizePairedVideo (10). A regular video has
            // neither. The Live Photo STILL (photo side) is NOT excluded — deleting
            // a Live Photo still via PhotoKit correctly removes both halves
            // atomically and is recoverable from Recently Deleted; only the orphaned
            // video half is dangerous.
            if asset.mediaType == .video {
                let resources = PHAssetResource.assetResources(for: asset)
                let isPairedVideo = resources.contains {
                    $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
                }
                if isPairedVideo { return }   // skip — deleting it orphans the Live Photo
            }
            assets.append(asset)
            map[asset.localIdentifier] = asset
        }
        assetsByID = map

        // Enrich with Apple's quality scores + real file size from the library's
        // Photos.sqlite (read-only). Loaded once and cached; degrades silently if
        // the database isn't readable (no Full Disk Access / non-standard path).
        if enrichment == nil {
            progress = t.progReadingQuality()
            progressFraction = nil   // length unknown — indeterminate
            let flag = abortFlag
            enrichment = await Task.detached(priority: .userInitiated) {
                QualitySidecar.load(shouldAbort: { flag.isSet })
            }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
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
        let exact = await detectExactDuplicates(in: built, t, fracBase: 0.9, fracSpan: 0.1)
        built = await seedExactRejections(in: built, exact: exact)
        if bailIfCancelled(t) { return }
        groups = built
        exactDupeGroupIDs = exact

        progressFraction = 1.0
        hasScanned = true
        // Verdicts were just proven against the CURRENT library — anchor the
        // staleness reference here (see `scanChangeToken`).
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        scanNotice = groups.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(groups.count)
        saveSnapshotNow()
    }

    /// Build a Core Photo from a PHAsset, enriched with Apple quality + size.
    ///
    /// STRICTLY cheap metadata only. `edited` is NOT computed here: its
    /// `PHAssetResource.assetResources` lookup costs an XPC round-trip per
    /// asset, and mapping the whole library through it was the real "reading
    /// quality scores" multi-minute stall (sampled live: ~80% of scan wall
    /// time inside PhotoFlags.edited), during which the main thread was too
    /// busy to even process the Cancel click. Like `isDocument`/`sharpness`,
    /// `edited` only matters for frames that end up in a group — enrichFlags
    /// fills it over cluster members only.
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
                     edited: false,   // filled by enrichFlags (cluster members only)
                     originalCamera: PhotoFlags.originalCamera(asset))
    }

    /// Fill the per-frame flags that are too expensive for the whole library —
    /// `isDocument`/`sharpness` (Vision/pixels) and `edited` (a per-asset
    /// PHAssetResource XPC round-trip) — over cluster members only. Returns the
    /// clusters with those photos rebuilt; quality/size (from `makePhoto`) are
    /// preserved.
    /// Bounded concurrency with a per-image timeout, like the scanners, so a stuck
    /// thumbnail can't stall it.
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
        await withTaskGroup(of: (String, Bool, Bool, Double, Bool).self) { group in
            var next = 0
            let limit = 8
            func add() {
                while !Task.isCancelled, next < uuids.count {   // cooperative cancel
                    let id = uuids[next]; next += 1
                    guard let a = lookup[id] else { continue }
                    let mgr = imageManager
                    group.addTask {
                        async let docResult = PhotoFlags.isDocumentResult(a, manager: mgr)
                        async let shp = PhotoFlags.sharpness(a, manager: mgr)
                        let edited = PhotoFlags.edited(a)
                        let (isDoc, degraded) = await docResult
                        return (id, isDoc, degraded, await shp, edited)
                    }
                    return
                }
            }
            for _ in 0..<limit { add() }
            for await (id, doc, degraded, shp, edited) in group {
                docs[id] = doc
                docsDegraded[id] = degraded
                sharps[id] = shp
                edits[id] = edited
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
                      documentEvalDegraded: docsDegraded[p.uuid] ?? p.documentEvalDegraded)
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

        var assets: [PHAsset] = []
        var map: [String: PHAsset] = [:]
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in
            // FIX 1 — Live Photo paired-video guard (same logic as scan()).
            if a.mediaType == .video {
                let resources = PHAssetResource.assetResources(for: a)
                let isPairedVideo = resources.contains {
                    $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
                }
                if isPairedVideo { return }
            }
            assets.append(a)
            map[a.localIdentifier] = a
        }
        assetsByID = map

        if enrichment == nil {
            progress = t.progReadingQuality()
            progressFraction = nil
            let flag = abortFlag
            enrichment = await Task.detached(priority: .userInitiated) {
                QualitySidecar.load(shouldAbort: { flag.isSet })
            }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
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
        let exact = await detectExactDuplicates(in: built, t, fracBase: 0.85, fracSpan: 0.15)
        built = await seedExactRejections(in: built, exact: exact)
        if bailIfCancelled(t) { return }
        groups = built
        exactDupeGroupIDs = exact

        progressFraction = 1.0
        hasScanned = true
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        scanNotice = groups.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(groups.count)
        saveSnapshotNow()
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

        var assets: [PHAsset] = []
        var map: [String: PHAsset] = [:]
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in
            // FIX 1 — Live Photo paired-video guard (same logic as scan()).
            if a.mediaType == .video {
                let resources = PHAssetResource.assetResources(for: a)
                let isPairedVideo = resources.contains {
                    $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
                }
                if isPairedVideo { return }
            }
            assets.append(a)
            map[a.localIdentifier] = a
        }
        assetsByID = map

        if enrichment == nil {
            progressFraction = nil
            let flag = abortFlag
            enrichment = await Task.detached(priority: .userInitiated) {
                QualitySidecar.load(shouldAbort: { flag.isSet })
            }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
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

        var albums: [CategoryBucket] = []
        var i = 0
        for ids in idGroups {
            if bailIfCancelled(t) { return }
            i += 1
            if i % 10 == 0 {
                progress = t.progNaming(i, idGroups.count)
                progressFraction = 0.65 + 0.35 * Double(i) / Double(max(idGroups.count, 1))
            }
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            guard photos.count >= 2 else { continue }
            let name = await albumName(for: photos, t: t)
            albums.append(CategoryBucket(label: name, photos: photos))
        }
        categories = albums.sorted { $0.count > $1.count }

        progressFraction = 1.0
        hasScanned = true
        scanChangeToken = ScanSnapshotStore.currentChangeTokenData()
        scanNotice = categories.isEmpty ? t.scanDoneNothing() : t.scanDoneBanner(categories.count)
        saveSnapshotNow()
    }

    /// Name a set from the Vision tags of its representative frame, prettified by
    /// apfel when available; otherwise the top tag (or a localized fallback).
    private func albumName(for photos: [Photo], t: L10n) async -> String {
        guard let rep = photos.first, let asset = assetsByID[rep.uuid] else { return t.setFallbackName() }
        let tags = await CategoryScanner.labels(for: asset, manager: imageManager)
        guard let top = tags.first else { return t.setFallbackName() }
        if let pretty = await Apfel.albumName(tags: tags) { return pretty }
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
            // Already keeping all — re-seed as if confident (reject non-keeper non-protected).
            let photos = groups[i].photos
            let keep = photos.first { $0.uuid == groups[i].keeperID } ?? photos[0]
            groups[i].rejected = Set(photos.compactMap { p in
                (p.uuid != keep.uuid && !p.isProtected) ? p.uuid : nil
            })
        } else {
            groups[i].rejected = []
            groups[i].includeProtected = false
        }
        groups[i].autoSeeded = []   // either way this was a user decision
        scheduleSnapshotSave()
    }

    /// Reject whole group: seed rejected = all non-keeper non-protected frames. `d` key.
    func rejectAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let photos = groups[i].photos
        let keep = photos.first { $0.uuid == groups[i].keeperID } ?? photos[0]
        groups[i].rejected = Set(photos.compactMap { p in
            (p.uuid != keep.uuid && !p.isProtected) ? p.uuid : nil
        })
        groups[i].autoSeeded = []   // user overrode — rejections are theirs now
        scheduleSnapshotSave()
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
        let protectedIDs = Set(groups[i].photos.filter(\.isProtected).map(\.uuid))
        if value {
            // The opt-in must actually mark the frames: rejectAll/toggle paths
            // always exclude protected frames, so without this insertion the
            // amber "Including protected (N)" state was a lie — deletionIDs
            // stayed unchanged and the N frames were silently kept.
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
        // Mutually exclusive with scans: a refine that completes over a newer
        // scan's groups would re-pick keepers from stale face scores and stomp
        // the scan's progress text.
        guard !refiningFaces, !isScanning else { return }
        refiningFaces = true
        defer { refiningFaces = false }

        let members = Array(Set(groups.flatMap { $0.photos.map(\.uuid) })
            .subtracting(faceScores.keys))
        var done = 0
        for uuid in members {
            if let asset = assetsByID[uuid] {
                faceScores[uuid] = await FaceScorer.score(asset: asset, manager: imageManager)
            }
            done += 1
            if done % 25 == 0 { progress = t.progFaces(done, members.count) }
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
                                     exact: Set<ReviewGroup.ID>) async -> [ReviewGroup] {
        guard !exact.isEmpty else { return built }
        var built = built
        for i in built.indices where exact.contains(built[i].id) {
            if Task.isCancelled || abortFlag.isSet { return built }   // caller bails + cleans up
            let keeperID = built[i].keeperID
            var seeds: Set<String> = []
            for (j, p) in built[i].photos.enumerated() {
                guard p.uuid != keeperID, !p.isProtected, !p.documentEvalDegraded else { continue }
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
    private func restampTokenAfterOwnWrite(wasCurrent: Bool) {
        if wasCurrent { scanChangeToken = ScanSnapshotStore.currentChangeTokenData() }
    }

    /// Persist the current review state immediately (scan end, after deletes).
    func saveSnapshotNow() {
        guard hasScanned else { return }
        snapshotSaveTask?.cancel()
        let snap = makeSnapshot()
        Task.detached(priority: .utility) { ScanSnapshotStore.save(snap) }
    }

    /// Persist after a decision change, debounced so a burst of keystrokes
    /// (x x x j x…) writes once, not per key.
    func scheduleSnapshotSave() {
        guard hasScanned, !isScanning else { return }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            // Re-check at fire time: if a scan started inside the debounce
            // window, `groups` is already wiped — persisting now would destroy
            // the previous snapshot.
            guard self?.isScanning == false else { return }
            self?.saveSnapshotNow()
        }
    }

    /// Rehydrate the last scan (groups + categories + decisions) from disk.
    /// Assets are re-fetched; anything unresolvable is dropped and a group that
    /// falls under 2 frames dissolves. Returns true when something was restored.
    @discardableResult
    func restoreSnapshot(_ t: L10n, quiet: Bool = false) -> Bool {
        guard !isScanning, groups.isEmpty, categories.isEmpty,
              let snap = ScanSnapshotStore.load() else { return false }

        let allIDs = Set(snap.groups.flatMap { $0.photos.map(\.uuid) }
            + snap.categories.flatMap { $0.photos.map(\.uuid) })
        guard !allIDs.isEmpty else { return false }

        // Must match the scan fetch: without includeAllBurstAssets the burst
        // sub-frames don't resolve and their groups silently dissolve on
        // restore (live-observed: 2755 → 2632 groups).
        let fetchOpts = PHFetchOptions()
        fetchOpts.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(allIDs), options: fetchOpts)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(fetched.count)
        fetched.enumerateObjects { a, _, _ in map[a.localIdentifier] = a }

        // A stale change token means the library was mutated after the scan —
        // scan-time verdicts (byte-verified exact, protection flags) can no
        // longer be trusted for DELETION. The user's own marks are theirs to
        // keep, but every APP-seeded suggestion is dropped and the exact
        // badges are cleared; a rescan re-proves them. Doctrine: pre-marks may
        // only exist while their byte-verified verdict is known-current.
        let tokenCurrent = ScanSnapshotStore.changeTokenIsCurrent(snap.changeToken)

        var restoredGroups: [ReviewGroup] = []
        var exactIDs: Set<ReviewGroup.ID> = []
        for gs in snap.groups {
            // Refresh the cheap live flags from the re-fetched assets: a photo
            // favorited OR edited since the scan must be protected NOW, not as of
            // the snapshot. Both are free metadata (isFavorite is a property;
            // PhotoFlags.edited is a synchronous adjustmentData check) — only
            // isDocument (Vision, pixels) still needs a rescan. When the token is
            // stale we re-check `edited` for the frames the user REJECTED, so a
            // frame edited after being rejected re-protects itself instead of
            // surviving inside the delete bucket.
            let rejectedSet = Set(gs.rejected)
            let photos: [Photo] = gs.photos.compactMap { p in
                guard let asset = map[p.uuid] else { return nil }
                let favNow = asset.isFavorite
                let editedNow = (!tokenCurrent && rejectedSet.contains(p.uuid) && !p.edited)
                    ? PhotoFlags.edited(asset) : p.edited
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
        guard !isWritingAlbums, !groups.isEmpty else { return t.albumsNothingNew() }
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
        restampTokenAfterOwnWrite(wasCurrent: wasCurrent)
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
        onBurstSkipped: ((Int) -> Void)? = nil
    ) async throws -> Int {
        // Never commit while a scan or face-refine is rebuilding group state:
        // a delete would race the pipeline over `groups` and persist a
        // half-built snapshot over the previous complete one.
        guard !isScanning, !refiningFaces else { return 0 }
        var ids = groups.flatMap(\.deletionIDs)
        guard !ids.isEmpty else { return 0 }

        // Resolve the deletion candidates from a LIVE fetch, never the scan-time
        // `assetsByID` snapshot. Two reasons: (1) an asset deleted OUTSIDE snapsift
        // (Photos.app on this Mac, another iCloud device) after the scan still
        // resolves in the stale map and would sail past the FIX 3 guard into
        // performChanges — a live fetch lets that guard catch in-session drift too;
        // (2) the protection sweep below must read the CURRENT favorite/edited
        // state, which a stale PHAsset can't provide.
        // Must match the scan/restore fetch: without includeAllBurstAssets the
        // burst sub-frames don't resolve by identifier and would be misread as
        // externally deleted (same gotcha restoreSnapshot documents).
        let liveOpts = PHFetchOptions()
        liveOpts.includeAllBurstAssets = true
        let liveFetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: liveOpts)
        var live: [String: PHAsset] = [:]
        live.reserveCapacity(liveFetch.count)
        liveFetch.enumerateObjects { a, _, _ in live[a.localIdentifier] = a }

        // Commit-time protection sweep: a frame favorited or edited SINCE the scan
        // is protected NOW — the same doctrine `restoreSnapshot` applies across
        // launches, enforced here for the live in-session window (hours long on a
        // big library, exactly when a user flips to Photos.app and stars/edits).
        // Drop any newly-protected frame from its group's delete bucket unless the
        // user force-opted-in for that group (`includeProtected` is per-group
        // informed consent). `favorite` is a free property; `edited` is a cheap
        // metadata call bounded by mark count, evaluated off-main. `isDocument`
        // (Vision/pixels) stays rescan-only. A newly-protected frame must never be
        // deleted without the ⇧X path, nor booked .exactDuplicate/.userRejected.
        let sweepTargets: [(gi: Int, uuid: String, asset: PHAsset)] =
            groups.indices.flatMap { i -> [(Int, String, PHAsset)] in
                guard !groups[i].includeProtected else { return [] }
                return groups[i].rejected.compactMap { uuid in
                    guard let asset = live[uuid],
                          let p = groups[i].photos.first(where: { $0.uuid == uuid }),
                          !p.isProtected else { return nil }
                    return (i, uuid, asset)
                }
            }
        if !sweepTargets.isEmpty {
            let flags = await withTaskGroup(of: (Int, String, Bool, Bool).self) { group -> [(Int, String, Bool, Bool)] in
                for target in sweepTargets {
                    let a = target.asset
                    group.addTask { (target.gi, target.uuid, a.isFavorite, PhotoFlags.edited(a)) }
                }
                var out: [(Int, String, Bool, Bool)] = []
                for await r in group { out.append(r) }
                return out
            }
            var dropped = 0
            for (gi, uuid, fav, edited) in flags where fav || edited {
                guard let j = groups[gi].photos.firstIndex(where: { $0.uuid == uuid }) else { continue }
                groups[gi].photos[j] = groups[gi].photos[j].with(favorite: fav, edited: edited)
                groups[gi].rejected.remove(uuid)
                groups[gi].autoSeeded.remove(uuid)
                dropped += 1
            }
            if dropped > 0 {
                onProtectedDropped?(dropped)
                ids = groups.flatMap(\.deletionIDs)   // shrink the commit set
                guard !ids.isEmpty else { saveSnapshotNow(); return 0 }
            }
        }

        var assets = ids.compactMap { live[$0] }
        guard !assets.isEmpty else { return 0 }

        // FIX 3: detect stale IDs (an asset removed outside snapsift since the
        // scan won't resolve in the live fetch).
        if assets.count != ids.count {
            let staleCount = ids.count - assets.count
            if let warn = staleWarning {
                let proceed = await warn(staleCount, assets.count)
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

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }

        // Append audit log (best-effort, never aborts the deletion).
        if !auditRecords.isEmpty {
            let session = DeletionSession(timestamp: timestamp, records: auditRecords)
            DeletionAuditLog.append(session)
        }

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
        restampTokenAfterOwnWrite(wasCurrent: tokenWasCurrent)

        // Keep the cross-launch snapshot in lockstep — a relaunch must never
        // resurrect frames that were just deleted.
        saveSnapshotNow()

        return assets.count
    }
}
