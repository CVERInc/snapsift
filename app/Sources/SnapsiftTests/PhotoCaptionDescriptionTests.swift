import Foundation
import Photos
import SnapsiftCore
@testable import SnapsiftPhotoKit

// Caption-derived description facts: mapping, batch core, session wiring and
// the exact pass. No test reads the Photos library or calls PhotoKit.

private final class CaptionNoImageManager: PHCachingImageManager, @unchecked Sendable {}

private struct CaptionHasher: OriginalBytesHasher {
    func sha256(itemIdentifier: String) async -> String? { "same" }
}

private struct CaptionFactsProbe: UniqueMetadataProbe {
    let described: [String: Bool]?
    func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata] {
        var out: [String: LibraryMetadata] = [:]
        for id in itemIdentifiers { out[id] = LibraryMetadata(albumCount: 0, hasDescription: described?[id]) }
        return out
    }
}

@MainActor
private final class CaptionPort: PhotoLibraryEnrichmentPort {
    var qualityAvailable: Bool { false }
    var libraryIdentity: LibraryIdentity { .unverified(.pathUnknown) }
    func loadEnrichment(assets: [PHAsset], shouldAbort: @escaping @Sendable () -> Bool) async {}
    func verifyLibraryIdentity(sample: [PHAsset]) async {}
    func discardCancelledLoad() {}
    func enrichment(for id: String) -> PhotoLibraryEnrichment? { nil }
    func assetMetadata(for asset: PHAsset) -> PhotoLibraryAssetMetadata { .init(filename: "", uti: "") }
    func editedFlags(for targets: [(uuid: String, asset: PHAsset)]) async -> [String: Bool]? { nil }
    func descriptions(for ids: [String]) async -> [String: Bool]? { ["port": true] }
    nonisolated func setName(tags: [String], language: String) async -> String? { nil }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func hit() { lock.lock(); n += 1; lock.unlock() }
}

@MainActor
func checkPhotoCaptionDescriptions() async {
    print("Photos caption description facts")

    let table: [(String?, Bool, String)] = [
        (nil, false, "nil"), ("", false, "empty"), ("   ", false, "spaces"),
        ("\n\t", false, "newline and tab"), ("a", true, "letter"), (" a ", true, "padded letter"),
        ("「字幕」", true, "non-Latin")]
    for (caption, expected, label) in table {
        check(photoCaptionDescribesAsset(caption) == expected, "caption mapping: \(label) is \(expected)")
    }

    let read: ([String]) async -> [(id: String, caption: String?)]? = { _ in
        [("C", "hello"), ("N", nil), ("E", ""), ("W", " \n ")]
    }
    let facts = await photoCaptionDescriptions(for: ["C", "N", "E", "W", "X"], read: read)
    check(facts == ["C": true, "N": false, "E": false, "W": false],
          "caption batch: captioned true, none/empty/whitespace false, omitted id absent")
    let failed = await photoCaptionDescriptions(for: ["C"], read: { _ in nil })
    check(failed == nil, "caption batch: a failed read is nil, never false")

    // Session wiring.
    let title = PhotoLibraryAlbumTitle(name: "fixture", candidateTitles: [])
    let titles = PhotoLibraryAlbumTitles(bursts: title, blurry: title, documents: title,
                                         exact: title, needsLook: title)
    func session(port: (any PhotoLibraryEnrichmentPort)?,
                 source: (@Sendable ([String]) async -> [String: Bool]?)?) -> PhotoLibrarySession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapsift-caption-\(UUID())")
        return PhotoLibrarySession(storage: PhotoLibraryStorage(directory: dir), albumTitles: titles,
                                   enrichment: port, descriptionSource: source,
                                   imageManager: CaptionNoImageManager())
    }
    let calls = CallCounter()
    let source: @Sendable ([String]) async -> [String: Bool]? = { _ in calls.hit(); return ["source": false] }
    let viaSource = await session(port: nil, source: source).libraryDescriptions(for: ["x"])
    check(viaSource == ["source": false] && calls.count == 1, "caption session: no port uses the source")
    let viaPort = await session(port: CaptionPort(), source: source).libraryDescriptions(for: ["x"])
    check(viaPort == ["port": true] && calls.count == 1, "caption session: the port wins and the source is not called")
    let neither = await session(port: nil, source: nil).libraryDescriptions(for: ["x"])
    check(neither == nil, "caption session: no port and no source is undetermined")

    // Exact pass with metadata built from caption facts.
    let pair = ReviewGroup(photos: [ph(1, 0), ph(2, 1)], keeperID: "U1")
    func run(_ described: [String: Bool]?) async -> ExactRejectionResult {
        let exact = await ExactDuplicatePass.detectExactDuplicates(
            in: [pair], hasher: CaptionHasher(), dHashes: { _ in ["U1": 42, "U2": 42] },
            featureSpread: { _ in 0 })
        return await ExactDuplicatePass.seedExactRejections(
            in: [pair], exact: exact, metadataProbe: CaptionFactsProbe(described: described),
            documentCheck: { _ in false })
    }
    let bare = await run(await photoCaptionDescriptions(for: ["U1", "U2"], read: { ids in ids.map { ($0, nil) } }))
    check(bare.groups[0].rejected == ["U2"] && bare.groups[0].autoSeeded == ["U2"],
          "caption exact pass: copies without captions pre-mark the non-keeper")
    let captioned = await run(await photoCaptionDescriptions(for: ["U1", "U2"], read: { _ in
        [("U1", nil), ("U2", "keep me")] }))
    check(captioned.groups[0].rejected.isEmpty && captioned.uniqueMetadataIDs == ["U2"],
          "caption exact pass: a caption on the non-keeper withholds the pre-mark and lists it")
    let unreadable = await run(await photoCaptionDescriptions(for: ["U1", "U2"], read: { _ in nil }))
    check(unreadable.groups[0].rejected.isEmpty && unreadable.uniqueMetadataWithheld == 1
          && unreadable.uniqueMetadataIDs.isEmpty,
          "caption exact pass: a failed read withholds without listing a metadata badge")
}
