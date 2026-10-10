import Foundation
import CoreGraphics
import SnapsiftCore
import SnapsiftVision

private struct FakeHasher: OriginalBytesHasher {
    let digests: [String: String]
    init(_ digests: [String: String]) { self.digests = digests }
    func sha256(itemIdentifier: String) async -> String? {
        return digests[itemIdentifier]
    }
}

private struct FakeMetadata: UniqueMetadataProbe {
    let facts: [String: LibraryMetadata]
    init(_ facts: [String: LibraryMetadata]) { self.facts = facts }
    func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata] {
        return facts
    }
}

@MainActor
func checkExactDuplicatePass() async {
    print("Exact-duplicate source ports")
    let pair = ReviewGroup(photos: [ph(1, 0), ph(2, 1)], keeperID: "U1")
    let plain = LibraryMetadata(albumCount: 0, hasDescription: false)
    let facts = ["U1": plain, "U2": plain]
    func run(_ group: ReviewGroup = pair, digests: [String: String] = ["U1": "same", "U2": "same"],
             metadata: [String: LibraryMetadata] = facts, document: Bool? = false,
             hashes: [String: UInt64] = ["U1": 42, "U2": 42], spread: Float? = 0)
        async -> (Set<ReviewGroup.ID>, ExactRejectionResult) {
        let hasher = FakeHasher(digests)
        let probe = FakeMetadata(metadata)
        let exact = await ExactDuplicatePass.detectExactDuplicates(
            in: [group], hasher: hasher, dHashes: { _ in hashes }, featureSpread: { _ in spread })
        let seeded = await ExactDuplicatePass.seedExactRejections(
            in: [group], exact: exact, metadataProbe: probe, documentCheck: { _ in document })
        return (exact, seeded)
    }

    let identical = await run()
    check(identical.0 == [pair.id] && identical.1.groups[0].rejected == ["U2"],
          "exact ports: byte-identical pair seeds only the non-keeper")
    check(identical.1.groups[0].autoSeeded == ["U2"], "exact ports: seeded attribution is preserved")
    let different = await run(digests: ["U1": "a", "U2": "b"])
    check(different.0.isEmpty && different.1.groups[0].rejected.isEmpty,
          "exact ports: differing original hashes never seed")
    for digests in [["U1": "same"], ["U2": "same"], [:]] {
        let result = await run(digests: digests)
        check(result.0.isEmpty && result.1.groups[0].rejected.isEmpty,
              "exact ports: unavailable original never certifies or seeds (available: \(digests.count))")
    }
    for unique in [LibraryMetadata(albumCount: 1, hasDescription: false),
                   LibraryMetadata(albumCount: 0, hasDescription: true)] {
        let result = await run(metadata: ["U1": plain, "U2": unique])
        check(result.0 == [pair.id] && result.1.groups[0].rejected.isEmpty
              && result.1.uniqueMetadataWithheld == 1 && result.1.uniqueMetadataIDs == ["U2"],
              "exact ports: unique metadata withholds the seed and keeps the exact badge")
    }
    for unknown in [LibraryMetadata(), LibraryMetadata(albumCount: 0), LibraryMetadata(hasDescription: false)] {
        let result = await run(metadata: ["U1": plain, "U2": unknown])
        check(result.1.groups[0].rejected.isEmpty && result.1.uniqueMetadataWithheld == 1
              && result.1.uniqueMetadataIDs.isEmpty,
              "exact ports: undetermined metadata withholds without inventing a metadata badge")
    }
    let unknownKeeper = await run(metadata: ["U2": plain])
    check(unknownKeeper.1.groups[0].rejected.isEmpty, "exact ports: unreadable keeper metadata also withholds")
    for (label, protected) in [("favorite", ph(2, 1, fav: true)), ("edited", ph(2, 1, edited: true)),
                               ("document", ph(2, 1, isDocument: true)),
                               ("document unknown", ph(2, 1, docDegraded: true)),
                               ("edit unknown", ph(2, 1, editedUnknown: true))] {
        let group = ReviewGroup(photos: [ph(1, 0), protected], keeperID: "U1")
        let result = await run(group)
        check(result.0 == [group.id] && result.1.groups[0].rejected.isEmpty,
              "exact ports: protected or unverifiable frame is never seeded (\(label))")
    }
    let document = await run(document: true)
    check(document.1.groups[0].photos[1].isDocument && document.1.groups[0].rejected.isEmpty,
          "exact ports: hi-Q document verdict upgrades protection instead of seeding")
    let unreadableDocument = await run(document: nil)
    check(unreadableDocument.1.groups[0].rejected.isEmpty, "exact ports: unreadable hi-Q document verdict never seeds")
    let changedPixels = await run(hashes: ["U1": 42, "U2": 43])
    check(changedPixels.0.isEmpty, "exact ports: dHash mismatch still stops byte verification")
    let distantPixels = await run(spread: ExactDuplicatePredicate.featureThreshold + 0.01)
    check(distantPixels.0.isEmpty, "exact ports: feature distance still rejects perceptual near-copies")
    let unreadablePixels = await run(hashes: ["U1": 42])
    check(unreadablePixels.0.isEmpty, "exact ports: unreadable perceptual member stays unverified")
    let unreadablePrint = await run(spread: nil)
    check(unreadablePrint.0.isEmpty, "exact ports: unreadable feature print stays unverified")

    let groups = (0..<11).map { _ in pairWithNewID(pair) }
    var detectionProgress: [(Int, Int)] = []
    let hasher = FakeHasher(["U1": "same", "U2": "same"])
    let exact = await ExactDuplicatePass.detectExactDuplicates(
        in: groups, hasher: hasher, dHashes: { _ in ["U1": 42, "U2": 42] }, featureSpread: { _ in 0 },
        progress: { detectionProgress.append(($0, $1)) })
    check(detectionProgress.map(\.0) == [0, 10] && detectionProgress.allSatisfy { $0.1 == 11 },
          "exact ports: detection progress retains the initial and every-tenth-group cadence")
    var seedProgress: [(Int, Int)] = []
    _ = await ExactDuplicatePass.seedExactRejections(
        in: groups, exact: exact, metadataProbe: FakeMetadata(facts), documentCheck: { _ in false },
        progress: { seedProgress.append(($0, $1)) })
    check(seedProgress.map(\.0) == Array(0...11) && seedProgress.allSatisfy { $0.1 == 11 },
          "exact ports: seeding progress retains each group's completion fraction")
    let cancelled = await ExactDuplicatePass.detectExactDuplicates(
        in: [pair], hasher: hasher, dHashes: { _ in [:] }, featureSpread: { _ in 0 }, isCancelled: { true })
    check(cancelled.isEmpty, "exact ports: cancellation returns a partial verdict without starting a group")
    var events: [String] = []
    _ = await ExactDuplicatePass.seedExactRejections(
        in: [pair], exact: [pair.id], metadataProbe: FakeMetadata(["U1": plain]),
        documentCheck: { _ in events.append("document"); return false },
        progress: { done, _ in events.append("progress:\(done)") },
        onMetadataWithheld: { id, determined in events.append("withheld:\(id):\(determined)") })
    check(events == ["progress:0", "withheld:U2:false", "progress:1"],
          "exact ports: withheld callback precedes completion and bypasses the document fetch")
}

private func pairWithNewID(_ group: ReviewGroup) -> ReviewGroup {
    ReviewGroup(photos: group.photos, keeperID: group.keeperID)
}

private actor FakeImages: ImageProvider {
    nonisolated let itemIdentifiers: Set<String>
    let images: [String: CGImage]
    private(set) var requests: [String: [ImageRequestProfile]] = [:]
    init(_ images: [String: CGImage], unreadable: Set<String> = []) {
        self.images = images
        itemIdentifiers = Set(images.keys).union(unreadable)
    }
    func image(for itemIdentifier: String, profile: ImageRequestProfile) async -> CGImage? {
        requests[itemIdentifier, default: []].append(profile)
        return images[itemIdentifier]
    }
}

/// Independent reference: the pre-extraction grayPixels9x8 CGContext path.
private func legacyDHash(_ image: CGImage) -> UInt64 {
    var data = [UInt8](repeating: 0, count: 9 * 8)
    let ctx = CGContext(data: &data, width: 9, height: 8, bitsPerComponent: 8,
                        bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
    return dHash(grayRowMajor: data.map(Int.init))
}

func checkImageProviderSeam() async {
    print("CGImage provider seam")
    let ctx = CGContext(data: nil, width: 90, height: 80, bitsPerComponent: 8,
                        bytesPerRow: 90, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    for y in 0..<8 {
        for x in 0..<9 {
            ctx.setFillColor(gray: CGFloat((x * 31 + y * 17) % 255) / 255, alpha: 1)
            ctx.fill(CGRect(x: x * 10, y: y * 10, width: 10, height: 10))
        }
    }
    let image = ctx.makeImage()!
    let provider = FakeImages(["pixels": image], unreadable: ["unreadable"])
    await LookAlikeScanner.clearCache()
    let hashes = await LookAlikeScanner.dHashesPublic(["pixels", "unreadable"], provider: provider)
    check(hashes["pixels"] == legacyDHash(image), "provider: stage-1 dHash matches the pre-refactor path for the same pixels")
    check(hashes["unreadable"] == nil, "provider: nil image is absent from hashes")
    let again = await LookAlikeScanner.dHashesPublic(["pixels", "unreadable"], provider: provider)
    check(again == hashes, "provider: repeated pass uses the same successful hash")
    let requests = await provider.requests
    check(requests["pixels"] == [.dHash], "provider: successful hash is fetched once with the dHash profile")
    check(requests["unreadable"] == [.dHash], "provider: failure cache prevents a hash retry within a scan")
    let cluster = [ph(1, 0), ph(2, 1)]
    let unreadable = FakeImages([:], unreadable: ["U1", "U2"])
    let verified = await LookAlikeScanner.verifyByContent([cluster], provider: unreadable, maxDistance: 8) { _, _ in }
    check(verified.count == 1 && verified[0].photos == cluster && verified[0].spread == Int.max,
          "provider: unreadable content verification leaves the cluster untouched and uncertain")
    _ = await LookAlikeScanner.featureSpreads([["U1", "U2"]], provider: unreadable) { _, _, _ in }
    let spreads = await LookAlikeScanner.featureSpreads([["U1", "U2"]], provider: unreadable) { _, _, _ in }
    check(spreads.count == 1 && spreads[0] == nil, "provider: any unreadable feature print yields uncertain spread")
    let failedRequests = await unreadable.requests
    check(failedRequests["U1"] == [.dHash, .featurePrint] && failedRequests["U2"] == [.dHash, .featurePrint],
          "provider: feature-print failure cache also prevents retries")
    await LookAlikeScanner.clearCache()
    _ = await LookAlikeScanner.dHashesPublic(["unreadable"], provider: provider)
    let newScanRequests = await provider.requests
    check(newScanRequests["unreadable"] == [.dHash, .dHash], "provider: clearing scan cache permits a new scan to retry")
    let nilProvider = FakeImages([:], unreadable: ["nil"])
    let local = await PhotoFlags.localThumb("nil", provider: nilProvider)
    let doc = await PhotoFlags.isDocumentResult("nil", provider: nilProvider, localCG: local)
    check(!doc.isDocument && doc.degraded, "provider: unreadable document thumbnail stays degraded")
    let docHighQuality = await PhotoFlags.isDocumentHiQ("nil", provider: nilProvider)
    check(docHighQuality == nil, "provider: unreadable high-quality document image stays unverified")
    let sharpness = await PhotoFlags.sharpness("nil", provider: nilProvider)
    check(sharpness == 0, "provider: unreadable sharpness image retains the zero ranking fallback")
    let faces = await FaceScorer.score(itemIdentifier: "nil", provider: nilProvider)
    check(faces == 0, "provider: unreadable faces image retains the zero score")
    let labels = await CategoryScanner.labels(for: "nil", provider: nilProvider)
    check(labels.isEmpty, "provider: unreadable category image retains the empty labels")
    let nilRequests = await nilProvider.requests
    check(nilRequests["nil"] == [.documentLocal, .documentLocal, .documentHighQuality,
                                   .documentLocal, .faceScoring, .categoryLabels],
          "provider: auxiliary analyzers select their original request profiles and document nil refetch")
    await LookAlikeScanner.clearCache()
}
