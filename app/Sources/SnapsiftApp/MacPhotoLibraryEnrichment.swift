import Foundation
import Photos
import SnapsiftCore
import SnapsiftPhotoKit

/// Optional macOS enrichment. The shared session owns every safety fallback.
@MainActor
final class MacPhotoLibraryEnrichment: PhotoLibraryEnrichmentPort {
    private var enrichment: [String: QualitySidecar.Enrichment]?
    private var sidecarPath = ""
    private static let identitySampleSize = 12
    private(set) var qualityAvailable = false
    private(set) var libraryIdentity: LibraryIdentity = .unverified(.pathUnknown)

    func discardCancelledLoad() {
        if enrichment?.isEmpty ?? false { enrichment = nil }
    }

    func enrichment(for id: String) -> PhotoLibraryEnrichment? {
        guard let e = enrichment?[QualitySidecar.zuuid(fromLocalIdentifier: id)] else { return nil }
        return PhotoLibraryEnrichment(quality: e.quality, size: e.size, edited: e.edited)
    }

    func assetMetadata(for asset: PHAsset) -> PhotoLibraryAssetMetadata {
        // Preserve the existing macOS metadata path; iOS uses public resources.
        PhotoLibraryAssetMetadata(
            filename: (asset.value(forKey: "filename") as? String) ?? "",
            uti: (asset.value(forKey: "uniformTypeIdentifier") as? String) ?? "")
    }

    func verifyLibraryIdentity(sample: [PHAsset]) async {
        await verifyIdentity(sample: sample)
    }

    nonisolated func setName(tags: [String], language: String) async -> String? {
        guard let language = Language(rawValue: language) else { return nil }
        return await Apfel.albumName(tags: tags, language: language)
    }

    func loadEnrichment(assets: [PHAsset], shouldAbort: @escaping @Sendable () -> Bool) async {
        guard enrichment?.isEmpty != false else { return }
        let loc = QualitySidecar.locate()
        sidecarPath = loc.path
        enrichment = await Task.detached(priority: .userInitiated) {
            QualitySidecar.load(libraryPath: loc.path, shouldAbort: shouldAbort)
        }.value
        qualityAvailable = !(enrichment?.isEmpty ?? true)
        guard qualityAvailable else {
            // Nothing was read, so there is nothing to trust; the existing Full
            // Disk Access hint already explains this case.
            libraryIdentity = .unverified(.pathUnknown)
            return
        }
        await verifyIdentity(sample: assets, location: loc)
    }

    /// Establish (or re-establish) whether the sidecar we would read is the
    /// library PhotoKit serves. Extracted from `loadEnrichmentIfNeeded` so the
    /// RESTORE path can run the same check: a launch that rehydrates yesterday's
    /// scan never called the scan path, so `libraryIdentity` stayed at its
    /// initial `.unverified(.pathUnknown)` forever — a permanent "can't confirm
    /// which library this Mac is using" banner on every launch with a snapshot,
    /// and a commit that fell back from ONE batched sidecar query to one
    /// sequential XPC round-trip per candidate (which, on a wedged lane, un-marks
    /// the user's whole review in the protective direction).
    ///
    /// `sample` is any set of live assets; the newest few are what the freshness
    /// probe needs. Cheap by construction: one WAL-aware query over ≤12 uuids.
    private func verifyIdentity(sample assets: [PHAsset],
                                       location: QualitySidecar.Location? = nil) async {
        let loc = location ?? QualitySidecar.locate()
        sidecarPath = loc.path
        // Sort the WHOLE input newest-first before sampling. `suffix(200)` was
        // only "the newest 200" when the caller happened to pass an ascending
        // list; scanSimilarSets fetches descending and the restore path passes
        // an unordered dictionary's values, so the probe was asking an old copy
        // about old photos and calling it verified (review r3 P2-1). Sorting
        // 121K PHAssets on a prefetched creationDate is milliseconds.
        let sample = assets
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .prefix(Self.identitySampleSize)
            .map { QualitySidecar.zuuid(fromLocalIdentifier: $0.localIdentifier) }
        let path = loc.path
        // ONE retry on a nil answer. `editedFlags` returns nil for "the probe
        // could not run" — SQLITE_BUSY while Photos writes, or an IO error — and
        // that is a transient state a second attempt usually clears. A nil that
        // survives the retry is reported as `.probeUnavailable`, NOT as
        // `.staleContents`: "your library file looks frozen" is a positive
        // finding, and inventing it out of a two-second lock is a banner that
        // lies. Both are untrusted; only one of them is news.
        var known = await Task.detached(priority: .userInitiated) {
            QualitySidecar.editedFlags(zuuids: sample, libraryPath: path)
        }.value
        if known == nil {
            known = await Task.detached(priority: .userInitiated) {
                QualitySidecar.editedFlags(zuuids: sample, libraryPath: path)
            }.value
        }
        libraryIdentity = evaluateLibraryIdentity(
            sidecarPath: loc.path,
            photosLibraryPath: loc.photosLibraryPath,
            sampledNewest: sample.count,
            foundInSidecar: known?.count)
    }

    func descriptions(for uuids: [String]) async -> [String: Bool]? {
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
        return described
    }

    func editedFlags(for targets: [(uuid: String, asset: PHAsset)]) async -> [String: Bool]? {
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
        return nil
    }

}
