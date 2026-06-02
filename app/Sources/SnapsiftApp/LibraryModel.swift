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

    // Clustering knobs (match the Python defaults).
    var gapSec = 3.0
    var sizeTol = 0.10
    var maxSpan = 30.0

    let imageManager = PHCachingImageManager()
    private var assetsByID: [String: PHAsset] = [:]

    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }
    var reclaimableCount: Int { totalDeletions }

    func asset(for id: String) -> PHAsset? { assetsByID[id] }

    func requestAccess() async {
        auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        progress = "Fetching library…"
        groups = []
        assetsByID = [:]
        defer { isScanning = false; progress = "" }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        opts.includeAllBurstAssets = true
        if !includeVideo {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        let result = PHAsset.fetchAssets(with: opts)

        var photos: [Photo] = []
        photos.reserveCapacity(result.count)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            map[id] = asset
            let uti = (asset.value(forKey: "uniformTypeIdentifier") as? String) ?? ""
            let name = (asset.value(forKey: "filename") as? String) ?? ""
            let taken = asset.creationDate?.timeIntervalSince1970 ?? 0
            // size is not cheaply available from PhotoKit; 0 makes clustering
            // size-permissive. The optional SQLite sidecar (Phase D) fills it in.
            photos.append(Photo(uuid: id, filename: name, takenAt: taken,
                                width: asset.pixelWidth, height: asset.pixelHeight,
                                size: 0, uti: uti,
                                kind: asset.mediaType == .video ? 1 : 0,
                                favorite: asset.isFavorite, quality: 0))
        }
        assetsByID = map

        progress = "Clustering \(photos.count) photos…"
        let clustered = cluster(photos, gapSec: gapSec, sizeTol: sizeTol, maxSpan: maxSpan)
        groups = clustered.map { ReviewGroup(photos: $0, keeperID: keeper($0).uuid) }
    }

    /// Promote a frame to keeper (favorites stay protected either way).
    func promote(group groupID: ReviewGroup.ID, to photoID: String) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keeperID = photoID
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
