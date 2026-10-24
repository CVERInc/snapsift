import Foundation
import SnapsiftCore
import SnapsiftVision

public struct FolderScanOptions: Sendable {
    public var iCloudDownloadPolicy: ICloudDownloadPolicy = .allowed
    public var iCloudDownloadTimeout: TimeInterval = 30
    public var gapSec = ScanMode.Burst.gapSec
    public var sizeTol = ScanMode.Burst.sizeTol
    public var maxSpan = ScanMode.Burst.maxSpan
    public var contentMaxDistance = ScanMode.burst.dHashDistance
    public var contentConfidentSpread = ScanMode.Burst.confidentSpread
    public var contentConfidentFeature: Float = ScanMode.burst.featureDistance
    public var lookAlikeHashDistance = ScanMode.lookAlikes.dHashDistance
    public var lookAlikeFeatureDistance: Float = ScanMode.lookAlikes.featureDistance

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
    public internal(set) var downloadedFiles: [FolderDownloadedFile] = []
    public var downloadedURLs: Set<URL> { Set(downloadedFiles.map(\.url)) }
    var ubiquityPort: FolderUbiquityPort = .system
    var downloadStore: FolderDownloadStore? = nil

    /// Evicts only this scan's recorded downloads, with per-file live gates.
    /// Keep the result/accesses alive until this call returns.
    public func evictDownloadedFiles() async -> [FolderICloudEvictionResult] {
        await Task.detached(priority: .utility) {
            if let downloadStore { return downloadStore.evict(downloadedFiles, port: ubiquityPort) }
            return FolderICloudAccess.evict(downloadedFiles, port: ubiquityPort)
        }.value
    }
    public let items: [FolderItem]
    public let groups: [ReviewGroup]
    public let exactGroupIDs: Set<ReviewGroup.ID>
    public let crossFolderDuplicates: [FolderCrossFolderDuplicate]
    public internal(set) var roots: [FolderScannedRoot]
    public let issues: [FolderEnumerationIssue]
    public let primaryHashes: [String: String]
    public let uniqueMetadataWithheld: Int
    public let uniqueMetadataIDs: Set<String>
    /// The withheld copies known to carry something the keeper lacks.
    public let knownCarryingIDs: Set<String>
    /// The withheld copies not known to carry anything (signals unreadable).
    public let undeterminedIDs: Set<String>
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
    public static func scan(roots: [URL], options: FolderScanOptions = FolderScanOptions(),
                            ubiquityPort: FolderUbiquityPort = .system,
                            downloadStore: FolderDownloadStore? = nil) async throws
        -> FolderScanResult {
        try await scan(roots: roots, mode: nil, options: options,
                       ubiquityPort: ubiquityPort, downloadStore: downloadStore)
    }

    public static func scan(roots: [URL], mode: ScanMode, options: FolderScanOptions = FolderScanOptions(),
                            ubiquityPort: FolderUbiquityPort = .system,
                            downloadStore: FolderDownloadStore? = nil) async throws -> FolderScanResult {
        try await scan(roots: roots, mode: Optional(mode), options: options,
                       ubiquityPort: ubiquityPort, downloadStore: downloadStore)
    }

    private static func scan(roots: [URL], mode: ScanMode?, options: FolderScanOptions,
                             ubiquityPort: FolderUbiquityPort,
                             downloadStore: FolderDownloadStore?) async throws -> FolderScanResult {
        let accesses = try roots.map { try FolderAccess(url: $0) }
        var succeeded = false
        defer { if !succeeded { accesses.forEach { $0.stop() } } }
        var scannedRoots: [FolderScannedRoot] = []
        var items: [FolderItem] = []
        var issues: [FolderEnumerationIssue] = []
        let cloud = FolderICloudAccess(policy: options.iCloudDownloadPolicy, port: ubiquityPort,
                                      timeout: options.iCloudDownloadTimeout, downloadStore: downloadStore,
                                      downloadRoots: try downloadStore?.prepare(roots: roots) ?? [:])
        defer { if downloadStore != nil { _ = cloud.downloadedFiles } }
        for access in accesses {
            try Task.checkCancellation()
            let root = access.url
            let enumerationTask = Task.detached(priority: .utility) {
                try FolderEnumerator.enumerate(root: root, cloud: cloud)
            }
            let enumeration: FolderEnumerationResult
            if downloadStore != nil {
                enumeration = try await withTaskCancellationHandler {
                    try await enumerationTask.value
                } onCancel: { enumerationTask.cancel() }
            } else {
                enumeration = try await enumerationTask.value
            }
            scannedRoots.append(FolderScannedRoot(url: root, volume: probeVolume(at: root)))
            items.append(contentsOf: enumeration.items)
            issues.append(contentsOf: enumeration.issues)
        }
        // Overlapping chosen roots must not duplicate one filesystem identity.
        var seen: Set<String> = []
        items = items.filter { seen.insert($0.id).inserted }
        let provider = FolderImageProvider(items: items, ubiquityPort: ubiquityPort)
        await LookAlikeScanner.clearCache()
        items = await enrich(items, provider: provider)
        try Task.checkCancellation()
        let grouped = try await group(items: items, mode: mode, options: options, provider: provider,
            hasher: FolderOriginalHasher(items: items, ubiquityPort: ubiquityPort),
            metadataProbe: FolderMetadataProbe(items: items),
            documentCheck: { await PhotoFlags.isDocumentHiQ($0, provider: provider) })
        let finalPhotos = Dictionary(uniqueKeysWithValues: grouped.groups.flatMap { $0.photos }.map { ($0.uuid, $0) })
        items = items.map { $0.with(photo: finalPhotos[$0.id] ?? $0.photo) }
        await LookAlikeScanner.clearCache()
        let downloadedFiles = cloud.downloadedFiles
        if let error = downloadStore?.persistenceError { throw error }
        succeeded = true
        return FolderScanResult(downloadedFiles: downloadedFiles, ubiquityPort: ubiquityPort, downloadStore: downloadStore,
                                items: items, groups: grouped.groups, exactGroupIDs: grouped.exact,
                                crossFolderDuplicates: grouped.cross, roots: scannedRoots, issues: issues,
                                primaryHashes: grouped.digests, uniqueMetadataWithheld: grouped.uniqueMetadataWithheld,
                                uniqueMetadataIDs: grouped.uniqueMetadataIDs,
                                knownCarryingIDs: grouped.knownCarryingIDs,
                                undeterminedIDs: grouped.undeterminedIDs,
                                imageProvider: provider, accesses: accesses)
    }

    struct Grouping {
        let groups: [ReviewGroup]
        let exact: Set<ReviewGroup.ID>
        let cross: [FolderCrossFolderDuplicate]
        let digests: [String: String]
        let uniqueMetadataWithheld: Int
        let uniqueMetadataIDs: Set<String>
        let knownCarryingIDs: Set<String>
        let undeterminedIDs: Set<String>
    }

    /// Enriched source facts and byte/metadata ports also admit deterministic fixtures.
    static func group(items: [FolderItem], mode: ScanMode?, options: FolderScanOptions = FolderScanOptions(),
                      provider: any ImageProvider, hasher: any OriginalBytesHasher,
                      metadataProbe: any UniqueMetadataProbe,
                      documentCheck: (String) async -> Bool?) async throws -> Grouping {
        let photos = items.map(\.photo).sorted(by: chronological)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        var verified: [LookAlikeScanner.VerifiedCluster] = []
        var confident: Set<Int> = []
        var lookAlikes: [[String]] = []
        if mode == .burst {
            let candidates = ScanMode.Burst.candidates(photos)
            try Task.checkCancellation()
            verified = await ScanMode.Burst.verifyContent(candidates, provider: provider) { _, _ in }
            try Task.checkCancellation()
            confident = await ScanMode.Burst.confidentIndices(verified, provider: provider) { _, _ in }
        } else if let mode {
            lookAlikes = await mode.scan(itemIdentifiers: photos.map(\.uuid), provider: provider) { _, _ in }
        } else {
            let clustered = cluster(photos, gapSec: options.gapSec,
                                    sizeTol: options.sizeTol, maxSpan: options.maxSpan)
            verified = await LookAlikeScanner.verifyByContent(
                clustered, provider: provider, maxDistance: options.contentMaxDistance) { _, _ in }
            let indices = verified.indices.filter { verified[$0].spread <= options.contentConfidentSpread }
            let spreads = await LookAlikeScanner.featureSpreads(
                indices.map { verified[$0].photos.map(\.uuid) }, provider: provider) { _, _, _ in }
            confident = Set(indices.enumerated().compactMap { offset, index in
                spreads[offset].map { $0 <= options.contentConfidentFeature ? index : nil } ?? nil
            })
            try Task.checkCancellation()
            lookAlikes = await LookAlikeScanner.scan(
                itemIdentifiers: photos.map(\.uuid), provider: provider,
                dHashDistance: options.lookAlikeHashDistance,
                featureDistance: options.lookAlikeFeatureDistance) { _, _ in }
        }
        try Task.checkCancellation()

        // Index full primary bytes independently of time/size/recall limits:
        // copies in different folders must still surface when dates differ.
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
        if mode == .burst {
            exactCandidates = verified.enumerated().map { index, verified in
                var group = ReviewGroup(photos: verified.photos, keeperID: keeper(verified.photos).uuid)
                group.confidentDupe = confident.contains(index)
                return group
            }
        } else if mode == .similarSets { exactCandidates = [] }
        let exact = await ExactDuplicatePass.detectExactDuplicates(
            in: exactCandidates.filter { group in
                group.photos.allSatisfy { byID[$0.uuid]?.members.count == 1 }
            }, hasher: CachedFolderHasher(digests: digests),
            dHashes: { await LookAlikeScanner.dHashesPublic($0, provider: provider) },
            featureSpread: { ids in
                let spread = await LookAlikeScanner.featureSpreads([ids], provider: provider) { _, _, _ in }
                return spread.first ?? nil
            })
        try Task.checkCancellation()
        // Exact components take priority. Remaining near groups are trimmed
        // without duplicating any item in the review/deletion surface.
        var built = mode == .burst ? exactCandidates : exactCandidates.filter { exact.contains($0.id) }
        var assigned = Set(built.flatMap { $0.photos.map(\.uuid) })
        for (index, verifiedGroup) in verified.enumerated() {
            appendReview(verifiedGroup.photos, confident: confident.contains(index),
                         groups: &built, assigned: &assigned)
        }
        for ids in lookAlikes {
            appendReview(ids.compactMap { byID[$0]?.photo }, confident: false,
                         groups: &built, assigned: &assigned)
        }
        let finalGroups: [ReviewGroup]
        let uniqueMetadataWithheld: Int
        let uniqueMetadataIDs: Set<String>
        let knownCarryingIDs: Set<String>
        let undeterminedIDs: Set<String>
        if mode == .similarSets {
            finalGroups = built
            uniqueMetadataWithheld = 0
            uniqueMetadataIDs = []
            knownCarryingIDs = []
            undeterminedIDs = []
        } else {
            let seeded = await seedFolderExactRejections(
                in: built, exact: exact, items: items,
                crossFolderItemIDs: Set(cross.flatMap(\.itemIDs)),
                metadataProbe: metadataProbe, documentCheck: documentCheck)
            finalGroups = seeded.groups
            uniqueMetadataWithheld = seeded.uniqueMetadataWithheld
            uniqueMetadataIDs = seeded.uniqueMetadataIDs
            knownCarryingIDs = seeded.knownCarryingIDs
            undeterminedIDs = seeded.undeterminedIDs
        }
        try Task.checkCancellation()
        return Grouping(groups: finalGroups, exact: exact, cross: cross, digests: digests,
                        uniqueMetadataWithheld: uniqueMetadataWithheld, uniqueMetadataIDs: uniqueMetadataIDs, knownCarryingIDs: knownCarryingIDs,
                        undeterminedIDs: undeterminedIDs)
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
