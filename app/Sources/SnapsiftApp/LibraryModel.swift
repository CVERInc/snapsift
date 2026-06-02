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

    func isKeeper(_ p: Photo) -> Bool { p.uuid == keeperID }
    func isDelete(_ p: Photo) -> Bool { p.uuid != keeperID && !p.favorite }
    var spanSec: Double { (photos.last?.takenAt ?? 0) - (photos.first?.takenAt ?? 0) }
    var hasFavorite: Bool { photos.contains { $0.favorite } }
    var hasVideo: Bool { photos.contains { $0.kind == 1 } }
    var deletionIDs: [String] { photos.filter(isDelete).map(\.uuid) }
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
    @Published var refiningFaces = false
    /// True once a face-refinement pass has re-picked keepers.
    @Published var facesApplied = false

    private var enrichment: [String: QualitySidecar.Enrichment]?
    private var faceScores: [String: Double] = [:]

    // Clustering knobs (match the Python defaults).
    var gapSec = 3.0
    var sizeTol = 0.10
    var maxSpan = 30.0

    let imageManager = PHCachingImageManager()
    private var assetsByID: [String: PHAsset] = [:]

    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }

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
        groups = clustered.map { ReviewGroup(photos: $0, keeperID: keeper($0).uuid) }
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

    /// Promote a frame to keeper (favorites stay protected either way).
    func promote(group groupID: ReviewGroup.ID, to photoID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keeperID = photoID
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
