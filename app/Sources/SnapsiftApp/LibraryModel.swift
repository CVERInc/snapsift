import Foundation
import Photos
import AppKit
import SnapsiftCore

/// One reviewable near-duplicate cluster: the Core photos plus the currently
/// chosen keeper. Favorites are never deletable regardless of keeper choice.
struct ReviewGroup: Identifiable {
    let id = UUID()
    let photos: [Photo]
    var keeperID: String
    /// When set, the whole group is kept — nothing is deleted. For groups that
    /// are perceptually similar but that the user wants to keep in full (e.g.
    /// several poses of the same subject).
    var keepAll = false
    /// A confident, near-identical burst (members barely differ) → safe to
    /// pre-mark for deletion. When false the frames differ enough that they may
    /// be distinct moments, so we don't pre-mark anything (keepAll defaults on).
    var confidentDupe = true

    func isKeeper(_ p: Photo) -> Bool { !keepAll && p.uuid == keeperID }
    func isDelete(_ p: Photo) -> Bool { !keepAll && p.uuid != keeperID && !p.favorite }
    var spanSec: Double { (photos.last?.takenAt ?? 0) - (photos.first?.takenAt ?? 0) }
    var hasFavorite: Bool { photos.contains { $0.favorite } }
    var hasVideo: Bool { photos.contains { $0.kind == 1 } }
    var deletionIDs: [String] { keepAll ? [] : photos.filter(isDelete).map(\.uuid) }
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
            acc + g.photos.filter { g.isDelete($0) }.reduce(0) { $0 + $1.size }
        }
    }

    func asset(for id: String) -> PHAsset? { assetsByID[id] }

    func requestAccess() async {
        auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
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
        let result = PHAsset.fetchAssets(with: opts)

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
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
        // suggesting you delete a frame that's actually a different moment.
        var built: [ReviewGroup] = []
        var n = 0
        for vc in verified {
            n += 1
            if n % 50 == 0 { progress = t.progConfirming(n, verified.count) }
            var confident = vc.spread <= contentConfidentSpread
            if confident {
                let fs = await LookAlikeScanner.featureSpread(
                    vc.photos.map(\.uuid), asset: { lookup[$0] }, manager: imageManager)
                confident = (fs != nil && fs! <= contentConfidentFeature)
            }
            var g = ReviewGroup(photos: vc.photos, keeperID: keeper(vc.photos).uuid)
            g.confidentDupe = confident
            g.keepAll = !confident            // uncertain groups: keep all, pre-mark nothing
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
        return Photo(uuid: id, filename: name,
                     takenAt: asset.creationDate?.timeIntervalSince1970 ?? 0,
                     width: asset.pixelWidth, height: asset.pixelHeight,
                     size: e?.size ?? 0, uti: uti,
                     kind: asset.mediaType == .video ? 1 : 0,
                     favorite: asset.isFavorite, quality: e?.quality ?? 0)
    }

    /// L3 cross-time pass: dHash-candidate + neural feature-print confirmation
    /// over the whole library. Heavier than the burst scan — shows progress.
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
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        var map: [String: PHAsset] = [:]
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a); map[a.localIdentifier] = a }
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

        groups = idGroups.compactMap { ids in
            let photos = ids.compactMap { map[$0] }.map { makePhoto(from: $0, enr: enr) }
                .sorted { $0.takenAt < $1.takenAt }
            guard photos.count >= 2 else { return nil }
            return ReviewGroup(photos: photos, keeperID: keeper(photos).uuid)
        }
    }

    /// "Similar sets": find sets of photos you took of the same thing — several
    /// near-same shots (like three poses of the same cat) — by clustering the
    /// whole library on visual similarity (looser than Look-alikes), then naming
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
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        var map: [String: PHAsset] = [:]
        assets.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in assets.append(a); map[a.localIdentifier] = a }
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

    /// Promote a frame to keeper (favorites stay protected either way).
    func promote(group groupID: ReviewGroup.ID, to photoID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keepAll = false
        groups[i].keeperID = photoID
    }

    /// Keep the entire group — exclude it from deletion. Toggles back off.
    func toggleKeepAll(group groupID: ReviewGroup.ID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keepAll.toggle()
    }

    /// Combined keeper key: favorites, then face score, then Apple quality, then
    /// format / size / earliest — an app-level extension of Core's `rankKey`.
    private func faceRankKey(_ p: Photo) -> (Int, Int, Int, Int, Int, Double) {
        (p.favorite ? 1 : 0,
         Int(((faceScores[p.uuid] ?? 0) * 100).rounded()),
         Int((p.quality * 10).rounded()),
         utiPriority[p.uti] ?? 0,
         p.size,
         -p.takenAt)
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

    /// Delete every reviewed non-keeper, non-favorite frame via PhotoKit. macOS
    /// shows its own confirmation; items land in Recently Deleted (30 days).
    /// Returns the number actually removed.
    @discardableResult
    func deleteReviewed() async throws -> Int {
        let ids = groups.flatMap(\.deletionIDs)
        let assets = ids.compactMap { assetsByID[$0] }
        guard !assets.isEmpty else { return 0 }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }

        // Drop deleted frames; a group that loses all but its keeper is resolved.
        let removed = Set(ids)
        groups = groups.compactMap { g in
            let remaining = g.photos.filter { !removed.contains($0.uuid) }
            guard remaining.count >= 2 else { return nil }
            let keeperID = remaining.contains { $0.uuid == g.keeperID }
                ? g.keeperID : keeper(remaining).uuid
            return ReviewGroup(photos: remaining, keeperID: keeperID)
        }
        return assets.count
    }
}
