import Foundation
import Photos
import AppKit
import SnapsiftCore

/// One reviewable near-duplicate cluster: the Core photos plus the currently
/// chosen keeper. Protected frames (favorite / edited / document — `Photo
/// .isProtected`) are never deletable by DEFAULT; the user can explicitly
/// force-reject them via the keyboard `⇧X` path or the mouse "include protected"
/// button, which both funnel through `setIncludeProtected` + a confirm dialog.
struct ReviewGroup: Identifiable {
    let id = UUID()
    let photos: [Photo]
    var keeperID: String
    /// Per-frame reject set: asset uuids the user wants deleted.
    /// SEEDED at scan time: confident groups seed all non-keeper non-protected
    /// frames; uncertain groups seed empty (keep all).
    /// A frame is a deletion iff its uuid is in this set — `isDelete` and
    /// `deletionIDs` derive purely from here.
    var rejected: Set<String> = []
    /// A confident, near-identical burst → safe to pre-seed rejections.
    /// When false the frames differ enough that the user should decide.
    ///
    /// FIX 4: default is FALSE — a group is uncertain until the scanner explicitly
    /// proves confidence (dHash spread ≤ threshold AND neural feature distance ≤
    /// threshold). Defaulting to true was "guilty until proven innocent": a group
    /// constructed without explicitly setting this flag would pre-seed rejections,
    /// which is the wrong, more-aggressive behaviour. Every construction site that
    /// wants confident behaviour MUST set confidentDupe = true explicitly.
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

    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }

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
        guard !isScanning else { return }
        isScanning = true
        progress = t.progFetching()
        groups = []
        categories = []
        assetsByID = [:]
        facesApplied = false
        defer { isScanning = false; progress = "" }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeAllBurstAssets = true
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        // Scope to the chosen source (whole library or a single album). If the
        // album can no longer be resolved (deleted since the picker showed it),
        // bail early rather than silently falling back to the whole library.
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            progress = t.progAlbumGone()
            isScanning = false
            return
        }

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
            enrichment = await Task.detached(priority: .userInitiated) {
                QualitySidecar.load()
            }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
        let enr = enrichment ?? [:]
        let enriched = assets.map { makePhoto(from: $0, enr: enr) }

        progress = t.progClustering(enriched.count)
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
        ) { [weak self] msg in Task { @MainActor in self?.progress = msg } }
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
            Task { @MainActor in self?.progress = t.progConfirming(done, total, loaded: loaded) }
        }
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
        }
        var built: [ReviewGroup] = []
        for (idx, photos) in flagged.enumerated() {
            let confident = neuralConfident.contains(idx)
            let keep = keeper(photos)
            var g = ReviewGroup(photos: photos, keeperID: keep.uuid)
            g.confidentDupe = confident
            if confident {
                // Seed rejections: all non-keeper, non-protected frames.
                // SLICE-1 INVARIANT: protected frames are NEVER auto-seeded.
                g.rejected = Set(photos.compactMap { p in
                    (p.uuid != keep.uuid && !p.isProtected) ? p.uuid : nil
                })
            }
            // Uncertain groups: rejected stays empty (keep all, user decides).
            built.append(g)
        }
        groups = built
    }

    /// Build a Core Photo from a PHAsset, enriched with Apple quality + size.
    private func makePhoto(from asset: PHAsset, enr: [String: QualitySidecar.Enrichment]) -> Photo {
        let id = asset.localIdentifier
        let e = enr[QualitySidecar.zuuid(fromLocalIdentifier: id)]
        let uti = (asset.value(forKey: "uniformTypeIdentifier") as? String) ?? ""
        let name = (asset.value(forKey: "filename") as? String) ?? ""
        // Cheap metadata-only flags computed here; the pixel-based ones
        // (isDocument, sharpness) are filled in by enrichFlags() over cluster
        // members only, so Vision never runs on the whole library.
        return Photo(uuid: id, filename: name,
                     takenAt: asset.creationDate?.timeIntervalSince1970 ?? 0,
                     width: asset.pixelWidth, height: asset.pixelHeight,
                     size: e?.size ?? 0, uti: uti,
                     kind: asset.mediaType == .video ? 1 : 0,
                     favorite: asset.isFavorite, quality: e?.quality ?? 0,
                     edited: PhotoFlags.edited(asset),
                     originalCamera: PhotoFlags.originalCamera(asset))
    }

    /// Fill the pixel-based flags (`isDocument`, `sharpness`) for the photos that
    /// belong to clusters — Vision/Laplacian never run on the whole library, only
    /// on frames that could actually be deleted or chosen as keeper. Returns the
    /// clusters with those photos rebuilt; `edited`/`originalCamera`/quality/size
    /// (already set in `makePhoto`) are preserved. Bounded concurrency with a
    /// per-image timeout, like the scanners, so a stuck thumbnail can't stall it.
    private func enrichFlags(_ clusters: [[Photo]],
                             progress: (Int, Int) -> Void) async -> [[Photo]] {
        let uuids = Array(Set(clusters.flatMap { $0.map(\.uuid) }))
        var docs: [String: Bool] = [:]
        var sharps: [String: Double] = [:]
        var done = 0
        let lookup = assetsByID
        await withTaskGroup(of: (String, Bool, Double).self) { group in
            var next = 0
            let limit = 8
            func add() {
                while next < uuids.count {
                    let id = uuids[next]; next += 1
                    guard let a = lookup[id] else { continue }
                    let mgr = imageManager
                    group.addTask {
                        async let doc = PhotoFlags.isDocument(a, manager: mgr)
                        async let shp = PhotoFlags.sharpness(a, manager: mgr)
                        return (id, await doc, await shp)
                    }
                    return
                }
            }
            for _ in 0..<limit { add() }
            for await (id, doc, shp) in group {
                docs[id] = doc; sharps[id] = shp
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
                      edited: p.edited, isDocument: docs[p.uuid] ?? p.isDocument,
                      sharpness: sharps[p.uuid] ?? p.sharpness,
                      originalCamera: p.originalCamera)
            }
        }
    }

    /// L3 cross-time pass: dHash-candidate + neural feature-print confirmation
    /// over the chosen source. Heavier than the burst scan — shows progress.
    func scanLookAlikes(_ t: L10n) async {
        guard !isScanning else { return }
        isScanning = true
        progress = t.progFetching()
        groups = []
        categories = []
        facesApplied = false
        defer { isScanning = false; progress = "" }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            progress = t.progAlbumGone()
            isScanning = false
            return
        }
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
            enrichment = await Task.detached(priority: .userInitiated) { QualitySidecar.load() }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
        let enr = enrichment ?? [:]

        let idGroups = await LookAlikeScanner.scan(assets: assets, manager: imageManager, t: t) { [weak self] msg in
            Task { @MainActor in self?.progress = msg }
        }

        let raw = idGroups.compactMap { ids -> [Photo]? in
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            return photos.count >= 2 ? photos : nil
        }
        // Document protection + sharpness ranking over the cluster members only.
        let enriched = await enrichFlags(raw) { done, total in
            self.progress = t.progVerifying(done, total)
        }
        groups = enriched.map { photos in
            // Look-alike groups are not auto-pre-marked (user decides).
            ReviewGroup(photos: photos, keeperID: keeper(photos).uuid)
        }
    }

    /// "Similar sets": find sets of photos you took of the same thing — several
    /// near-same shots (like three poses of the same cat) — by clustering the
    /// chosen source on visual similarity (looser than Look-alikes), then naming
    /// each set from its Vision content tags (prettified by apfel if available).
    /// No deletion — this is for browsing/curation.
    func scanSimilarSets(_ t: L10n) async {
        guard !isScanning else { return }
        isScanning = true
        progress = t.progFetching()
        groups = []
        categories = []
        assetsByID = [:]
        facesApplied = false
        defer { isScanning = false; progress = "" }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        guard let result = fetchAssets(source: scanSource, options: opts) else {
            progress = t.progAlbumGone()
            isScanning = false
            return
        }
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
            enrichment = await Task.detached(priority: .userInitiated) { QualitySidecar.load() }.value
            qualityAvailable = !(enrichment?.isEmpty ?? true)
        }
        let enr = enrichment ?? [:]

        // Cluster the library at the "same scene, different moment" band — looser
        // than Look-alikes (which is now ≈identical only), so pose/angle changes
        // still group (cats ≈0.3 feature distance land here, not in Look-alikes).
        let idGroups = await LookAlikeScanner.scan(
            assets: assets, manager: imageManager, t: t,
            dHashDistance: 14, featureDistance: 0.45
        ) { [weak self] msg in Task { @MainActor in self?.progress = msg } }

        var albums: [CategoryBucket] = []
        var i = 0
        for ids in idGroups {
            i += 1
            if i % 10 == 0 { progress = t.progNaming(i, idGroups.count) }
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            guard photos.count >= 2 else { continue }
            let name = await albumName(for: photos)
            albums.append(CategoryBucket(label: name, photos: photos))
        }
        categories = albums.sorted { $0.count > $1.count }
    }

    /// Name a set from the Vision tags of its representative frame, prettified by
    /// apfel when available; otherwise the top tag (or a generic fallback).
    private func albumName(for photos: [Photo]) async -> String {
        guard let rep = photos.first, let asset = assetsByID[rep.uuid] else { return "Set" }
        let tags = await CategoryScanner.labels(for: asset, manager: imageManager)
        guard let top = tags.first else { return "Set" }
        if let pretty = await Apfel.albumName(tags: tags) { return pretty }
        return CategoryScanner.displayName(top)
    }

    /// Promote a frame to keeper: clear its rejection AND set it as keeper ★.
    /// ⏎ action in grid and loupe.
    func promote(group groupID: ReviewGroup.ID, to photoID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keeperID = photoID
        groups[i].rejected.remove(photoID)   // un-reject the new keeper
    }

    /// Keep the entire group — clear all rejections. `a` key.
    func keepAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].rejected = []
        groups[i].includeProtected = false
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
    }

    /// Reject whole group: seed rejected = all non-keeper non-protected frames. `d` key.
    func rejectAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let photos = groups[i].photos
        let keep = photos.first { $0.uuid == groups[i].keeperID } ?? photos[0]
        groups[i].rejected = Set(photos.compactMap { p in
            (p.uuid != keep.uuid && !p.isProtected) ? p.uuid : nil
        })
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
    }

    /// Toggle reject on a single frame. `X` / `⌫` key.
    /// Protected frames: plain toggle is a NO-OP (returns false, caller shows hint).
    /// Returns true if the toggle happened, false if blocked (protected frame).
    @discardableResult
    func toggleReject(group groupID: ReviewGroup.ID, frameID: String) -> Bool {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        guard let p = groups[i].photos.first(where: { $0.uuid == frameID }) else { return false }
        if p.isProtected { return false }   // blocked — caller shows hint
        if groups[i].rejected.contains(frameID) {
            groups[i].rejected.remove(frameID)
        } else {
            groups[i].rejected.insert(frameID)
            // If rejecting the current keeper, promote to next best.
            if frameID == groups[i].keeperID {
                let remaining = groups[i].photos.filter { !groups[i].rejected.contains($0.uuid) }
                if let next = remaining.max(by: { rankKey($0) < rankKey($1) }) {
                    groups[i].keeperID = next.uuid
                }
            }
        }
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
    }

    /// Explicit opt-in to include protected frames in the deletion set for this group.
    /// NEVER called by the scanner; UI-only action that requires prior confirmation.
    func setIncludeProtected(group groupID: ReviewGroup.ID, value: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].includeProtected = value
        if !value {
            // Removing override: un-reject all protected frames.
            let protectedIDs = Set(groups[i].photos.filter(\.isProtected).map(\.uuid))
            groups[i].rejected.subtract(protectedIDs)
        }
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
        guard !refiningFaces else { return }
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
            return ng
        }
        facesApplied = true
        progress = ""
    }

    // MARK: - Exact-duplicate detection (Part B)

    /// Run the exact-duplicate predicate over the current groups to identify
    /// which ones are genuine re-saves (not just bursts). This is called by
    /// `scanLookAlikes` where feature prints are already available, and also
    /// on demand after any scan via the toolbar button.
    ///
    /// A group qualifies as exact-duplicate when:
    ///   - All members share the same pixel dimensions, AND
    ///   - The max pairwise dHash Hamming distance == 0, AND
    ///   - The max pairwise feature-print distance ≤ ExactDuplicatePredicate.featureThreshold
    ///
    /// The result is stored in `exactDupeGroupIDs` for the UI and AlbumWriter.
    func detectExactDuplicates(_ t: L10n) async {
        guard !groups.isEmpty else { exactDupeGroupIDs = []; return }
        progress = t.progVerifying(0, groups.count)

        // We need feature prints for the dimension+dHash-consistent groups.
        // Re-use the existing photo hashes via a lightweight second pass.
        // All hashing and print computation runs off the main actor.
        let snapshot = groups
        let lookup = assetsByID
        let mgr = imageManager

        var exact: Set<ReviewGroup.ID> = []
        var done = 0
        for g in snapshot {
            defer { done += 1; if done % 10 == 0 { progress = t.progVerifying(done, snapshot.count) } }
            guard g.photos.count >= 2 else { continue }

            // 1. Same dimensions: all members must match the first frame.
            let w0 = g.photos[0].width, h0 = g.photos[0].height
            guard g.photos.allSatisfy({ $0.width == w0 && $0.height == h0 }) else { continue }

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

            exact.insert(g.id)
        }

        exactDupeGroupIDs = exact
        progress = ""
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

        let result = try await AlbumWriter.write(
            groups: groups,
            exactGroups: exactDupeGroupIDs,
            assetsByID: assetsByID,
            t: t
        )
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
        staleWarning: ((Int, Int) async -> Bool)? = nil
    ) async throws -> Int {
        let ids = groups.flatMap(\.deletionIDs)
        let assets = ids.compactMap { assetsByID[$0] }
        guard !assets.isEmpty else { return 0 }

        // FIX 3: detect stale IDs (library mutated since scan).
        if assets.count != ids.count {
            let staleCount = ids.count - assets.count
            if let warn = staleWarning {
                let proceed = await warn(staleCount, assets.count)
                guard proceed else { return 0 }
            }
            // No warning handler supplied: proceed silently with found assets
            // (legacy callers that don't pass the closure get existing behavior).
        }

        // Build audit records BEFORE the delete (photos still exist in model).
        let timestamp = DeletionAuditLog.nowTimestamp()
        var auditRecords: [DeletionRecord] = []
        for g in groups {
            let deletionIDs = g.deletionIDs
            guard !deletionIDs.isEmpty else { continue }
            let keeperPhoto = g.photos.first { $0.uuid == g.keeperID }
            let keeperID = g.keeperID
            let keeperFilename = keeperPhoto?.filename ?? ""
            for deletedID in deletionIDs {
                guard let p = g.photos.first(where: { $0.uuid == deletedID }) else { continue }
                let reason = DeletionAuditLog.reason(for: p, includeProtectedActive: g.includeProtected)
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
        let removed = Set(ids)
        groups = groups.compactMap { g -> ReviewGroup? in
            guard let r = regroupAfterDeletion(photos: g.photos,
                                               keeperID: g.keeperID,
                                               removed: removed) else { return nil }
            var ng = ReviewGroup(photos: r.photos, keeperID: r.keeperID)
            ng.confidentDupe = g.confidentDupe
            // Carry forward only the rejections that still exist in the remaining photos.
            ng.rejected = g.rejected.filter { id in r.photos.contains { $0.uuid == id } }
            // includeProtected is intentionally NOT carried forward: after a delete
            // pass the protected frames that were opted-in are already gone, and the
            // remaining group should start fresh (default = protected, as always).
            ng.includeProtected = false
            return ng
        }
        return assets.count
    }
}
