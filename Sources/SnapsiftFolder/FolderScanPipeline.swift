import Foundation
import SnapsiftCore
import SnapsiftVision

public struct FolderScanOptions: Sendable {
    public var gapSec = 3.0
    public var sizeTol = 0.10
    public var maxSpan = 30.0
    public var contentMaxDistance = 14
    public var contentConfidentSpread = 6
    public var contentConfidentFeature: Float = 0.10
    public var lookAlikeHashDistance = 8
    public var lookAlikeFeatureDistance: Float = 0.15

    public init() {}
}

public struct FolderScannedRoot {
    public let url: URL
    public let volume: VolumeProbeResult
}

/// Matching PRIMARY bytes across locations; companions are not certified by
/// this informational result and it never authorizes a pre-mark.
public struct FolderCrossFolderDuplicate {
    public let primarySHA256: String
    public let itemIDs: [String]
    public let folderKeys: Set<String>
}

public struct FolderScanResult {
    public let items: [FolderItem]
    public let groups: [ReviewGroup]
    public let exactGroupIDs: Set<ReviewGroup.ID>
    public let crossFolderDuplicates: [FolderCrossFolderDuplicate]
    public let roots: [FolderScannedRoot]
    public let issues: [FolderEnumerationIssue]
    public let primaryHashes: [String: String]
    public let uniqueMetadataWithheld: Int
    public let uniqueMetadataIDs: Set<String>
    public let imageProvider: FolderImageProvider
    /// Retain while reviewing/using member URLs; stop when the session closes.
    public let accesses: [FolderAccess]
}

private struct CachedFolderHasher: OriginalBytesHasher {
    let digests: [String: String]
    func sha256(itemIdentifier: String) async -> String? { digests[itemIdentifier] }
}

/// Core compares captions relative to the keeper. Folder Mode's owner instead
/// protects ANY tagged/commented candidate. A determined keeper is neutralized
/// only for that comparison; unknown keeper facts still block all suggestions.
private struct FolderSeedingMetadata: UniqueMetadataProbe {
    let probe: any UniqueMetadataProbe
    let keeperIDs: Set<String>
    func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata] {
        var facts = await probe.metadata(for: itemIdentifiers)
        for id in keeperIDs {
            if let fact = facts[id], fact.isFullyDetermined {
                facts[id] = LibraryMetadata(albumCount: fact.albumCount, hasDescription: false)
            }
        }
        return facts
    }
}

/// Folder-only eligibility around the unchanged Core exact seeder. A mixed
/// location group withholds ALL pre-marks, even its same-folder subset. A copy
/// whose only twin is elsewhere can therefore never enter the seeded set.
@MainActor
public func seedFolderExactRejections(
    in groups: [ReviewGroup], exact: Set<ReviewGroup.ID>,
    items: [FolderItem], crossFolderItemIDs: Set<String> = [],
    metadataProbe: any UniqueMetadataProbe,
    documentCheck: (String) async -> Bool?
) async -> ExactRejectionResult {
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let eligible = groups.filter { group in
        guard exact.contains(group.id) else { return false }
        let members = group.photos.compactMap { byID[$0.uuid] }
        return members.count == group.photos.count
            && members.allSatisfy { $0.members.count == 1 && !crossFolderItemIDs.contains($0.id) }
            && Set(members.map(\.folderKey)).count == 1
    }
    return await ExactDuplicatePass.seedExactRejections(
        in: groups, exact: Set(eligible.map(\.id)),
        metadataProbe: FolderSeedingMetadata(probe: metadataProbe, keeperIDs: Set(eligible.map(\.keeperID))),
        documentCheck: documentCheck)
}

/// Uses the same Core time clustering/ranking, Vision content verification and
/// look-alike pass, and Core exact verification/seeding as Apple Photos Mode.
/// No Photos stores or commit effects are reachable from this pipeline.
@MainActor
public enum FolderScanPipeline {
    public static func scan(roots: [URL], options: FolderScanOptions = FolderScanOptions()) async throws
        -> FolderScanResult {
        let accesses = try roots.map { try FolderAccess(url: $0) }
        var succeeded = false
        defer { if !succeeded { accesses.forEach { $0.stop() } } }
        var scannedRoots: [FolderScannedRoot] = []
        var items: [FolderItem] = []
        var issues: [FolderEnumerationIssue] = []
        for access in accesses {
            try Task.checkCancellation()
            let root = access.url
            let enumeration = try await Task.detached(priority: .utility) {
                try FolderEnumerator.enumerate(root: root)
            }.value
            scannedRoots.append(FolderScannedRoot(url: root, volume: probeVolume(at: root)))
            items.append(contentsOf: enumeration.items)
            issues.append(contentsOf: enumeration.issues)
        }
        // Overlapping chosen roots must not duplicate one filesystem identity.
        var seen: Set<String> = []
        items = items.filter { seen.insert($0.id).inserted }
        let provider = FolderImageProvider(items: items)
        await LookAlikeScanner.clearCache()
        items = await enrich(items, provider: provider)
        try Task.checkCancellation()
        let photos = items.map(\.photo).sorted(by: chronological)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let clustered = cluster(photos, gapSec: options.gapSec,
                                sizeTol: options.sizeTol, maxSpan: options.maxSpan)
        let verified = await LookAlikeScanner.verifyByContent(
            clustered, provider: provider, maxDistance: options.contentMaxDistance) { _, _ in }
        let confidentIndices = verified.indices.filter { verified[$0].spread <= options.contentConfidentSpread }
        let spreads = await LookAlikeScanner.featureSpreads(
            confidentIndices.map { verified[$0].photos.map(\.uuid) }, provider: provider) { _, _, _ in }
        let confident = Set(confidentIndices.enumerated().compactMap { offset, index in
            spreads[offset].map { $0 <= options.contentConfidentFeature ? index : nil } ?? nil
        })
        try Task.checkCancellation()
        let lookAlikes = await LookAlikeScanner.scan(
            itemIdentifiers: photos.map(\.uuid), provider: provider,
            dHashDistance: options.lookAlikeHashDistance,
            featureDistance: options.lookAlikeFeatureDistance) { _, _ in }
        try Task.checkCancellation()

        // Index full primary bytes independently of time/size/recall limits:
        // copies in different folders must still surface when dates differ.
        let hasher = FolderOriginalHasher(items: items)
        var digests: [String: String] = [:]
        for item in items {
            try Task.checkCancellation()
            if let digest = await hasher.sha256(itemIdentifier: item.id) { digests[item.id] = digest }
        }
        let byteBuckets = Dictionary(grouping: items.filter { digests[$0.id] != nil }) { digests[$0.id]! }
        var cross: [FolderCrossFolderDuplicate] = []
        var exactCandidates: [ReviewGroup] = []
        for digest in byteBuckets.keys.sorted() {
            let bucket = byteBuckets[digest]!
            let folders = Set(bucket.map(\.folderKey))
            if folders.count > 1 {
                cross.append(FolderCrossFolderDuplicate(primarySHA256: digest,
                                                        itemIDs: bucket.map(\.id).sorted(), folderKeys: folders))
            }
            // A primary-only hash cannot certify un-hashed motion/RAW/sidecars.
            let singles = bucket.filter { $0.members.count == 1 }.map(\.photo).sorted(by: chronological)
            if singles.count >= 2 {
                var group = ReviewGroup(photos: singles, keeperID: keeper(singles).uuid)
                group.confidentDupe = true
                exactCandidates.append(group)
            }
        }
        let exact = await ExactDuplicatePass.detectExactDuplicates(
            in: exactCandidates, hasher: CachedFolderHasher(digests: digests),
            dHashes: { await LookAlikeScanner.dHashesPublic($0, provider: provider) },
            featureSpread: { ids in
                let spread = await LookAlikeScanner.featureSpreads([ids], provider: provider) { _, _, _ in }
                return spread.first ?? nil
            })
        try Task.checkCancellation()
        // Exact components take priority. Remaining near groups are trimmed
        // without duplicating any item in the review/deletion surface.
        var built = exactCandidates.filter { exact.contains($0.id) }
        var assigned = Set(built.flatMap { $0.photos.map(\.uuid) })
        for (index, verifiedGroup) in verified.enumerated() {
            appendReview(verifiedGroup.photos, confident: confident.contains(index),
                         groups: &built, assigned: &assigned)
        }
        for ids in lookAlikes {
            appendReview(ids.compactMap { byID[$0]?.photo }, confident: false,
                         groups: &built, assigned: &assigned)
        }
        let seeded = await seedFolderExactRejections(
            in: built, exact: exact, items: items,
            crossFolderItemIDs: Set(cross.flatMap(\.itemIDs)),
            metadataProbe: FolderMetadataProbe(items: items),
            documentCheck: { await PhotoFlags.isDocumentHiQ($0, provider: provider) })
        try Task.checkCancellation()
        let finalPhotos = Dictionary(uniqueKeysWithValues: seeded.groups.flatMap { $0.photos }.map { ($0.uuid, $0) })
        items = items.map { $0.with(photo: finalPhotos[$0.id] ?? $0.photo) }
        await LookAlikeScanner.clearCache()
        succeeded = true
        return FolderScanResult(items: items, groups: seeded.groups, exactGroupIDs: exact,
                                crossFolderDuplicates: cross, roots: scannedRoots, issues: issues,
                                primaryHashes: digests, uniqueMetadataWithheld: seeded.uniqueMetadataWithheld,
                                uniqueMetadataIDs: seeded.uniqueMetadataIDs,
                                imageProvider: provider, accesses: accesses)
    }

    private static func chronological(_ a: Photo, _ b: Photo) -> Bool {
        a.takenAt == b.takenAt ? a.uuid < b.uuid : a.takenAt < b.takenAt
    }

    private static func appendReview(_ photos: [Photo], confident: Bool,
                                     groups: inout [ReviewGroup], assigned: inout Set<String>) {
        let remaining = photos.filter { !assigned.contains($0.uuid) }.sorted(by: chronological)
        guard remaining.count >= 2 else { return }
        var group = ReviewGroup(photos: remaining, keeperID: keeper(remaining).uuid)
        group.confidentDupe = confident
        groups.append(group)
        assigned.formUnion(remaining.map(\.uuid))
    }

    private static func enrich(_ items: [FolderItem], provider: FolderImageProvider) async -> [FolderItem] {
        var flags: [String: (Bool, Bool, Double)] = [:]
        await withTaskGroup(of: (String, Bool, Bool, Double).self) { group in
            var next = 0
            func add() {
                guard !Task.isCancelled, next < items.count else { return }
                let id = items[next].id
                next += 1
                group.addTask {
                    let thumbnail = await PhotoFlags.localThumb(id, provider: provider)
                    let doc = await PhotoFlags.isDocumentResult(id, provider: provider, localCG: thumbnail)
                    return (id, doc.isDocument, doc.degraded, thumbnail.map(PhotoFlags.sharpness(from:)) ?? 0)
                }
            }
            for _ in 0..<8 { add() }
            for await (id, doc, degraded, sharpness) in group {
                flags[id] = (doc, degraded, sharpness)
                add()
            }
        }
        return items.map { item in
            let p = item.photo
            let (document, degraded, sharpness) = flags[item.id] ?? (false, true, 0)
            return item.with(photo: Photo(
                uuid: p.uuid, filename: p.filename, takenAt: p.takenAt,
                width: p.width, height: p.height, size: p.size, uti: p.uti,
                kind: 0, favorite: false, quality: 0, edited: p.edited,
                isDocument: document, sharpness: sharpness, originalCamera: p.originalCamera,
                documentEvalDegraded: degraded, editedUndetermined: false))
        }
    }
}
