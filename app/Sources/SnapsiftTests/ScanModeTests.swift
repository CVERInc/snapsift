import Foundation
import CoreGraphics
import SnapsiftCore
import SnapsiftVision
import SnapsiftPhotoKit

private actor ScanModeImages: ImageProvider {
    nonisolated let itemIdentifiers: Set<String>
    let images: [String: CGImage]
    private(set) var profiles: [ImageRequestProfile] = []
    init(_ images: [String: CGImage]) {
        self.images = images
        itemIdentifiers = Set(images.keys)
    }
    func image(for itemIdentifier: String, profile: ImageRequestProfile) async -> CGImage? {
        profiles.append(profile)
        return images[itemIdentifier]
    }
}

/// Seeded mosaics have distinct dHashes. Tint varies the feature print without
/// changing the layout. No bundled photos, files, or source-specific adapters.
private func scanModeImage(seed: UInt64, tint: Double = 0) -> CGImage {
    let ctx = CGContext(data: nil, width: 180, height: 160, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var state = seed
    for y in 0..<8 {
        for x in 0..<9 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let gray = 0.15 + Double((state >> 32) % 160) / 255
            ctx.setFillColor(CGColor(red: gray, green: gray * (1 - tint * 0.7),
                                     blue: gray * (1 - tint), alpha: 1))
            ctx.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
        }
    }
    return ctx.makeImage()!
}

private struct ScanModeGolden: Equatable {
    let ids: [String]
    let confident: Bool
    init(_ ids: [String], _ confident: Bool = false) {
        self.ids = ids.sorted()
        self.confident = confident
    }
}

private func sortedGolden(_ groups: [ScanModeGolden]) -> [ScanModeGolden] {
    groups.sorted { $0.ids.lexicographicallyPrecedes($1.ids) }
}

private func burstGolden(_ groups: [LookAlikeScanner.VerifiedCluster], _ confident: Set<Int>) -> [ScanModeGolden] {
    sortedGolden(groups.enumerated().map { ScanModeGolden($0.element.photos.map(\.uuid), confident.contains($0.offset)) })
}

private func idGolden(_ groups: [[String]]) -> [ScanModeGolden] {
    sortedGolden(groups.map { ScanModeGolden($0) })
}

private struct ScanModeEvent: Equatable {
    let message: String
    let fraction: Double?
    init(_ progress: LookAlikeScanner.Progress, _ fraction: Double?) {
        switch progress {
        case .hashing(let done, let total): message = "hashing:\(done):\(total)"
        case .confirming(let done, let total, let loaded): message = "confirming:\(done):\(total):\(loaded)"
        case .verifying(let done, let total): message = "verifying:\(done):\(total)"
        case .skippedClusters(let count): message = "skipped:\(count)"
        }
        self.fraction = fraction
    }
}

/// Literal f84c952 Photos comparison, independent of ScanMode's values/methods.
private func referenceScanMode(_ mode: ScanMode, photos: [Photo], provider: any ImageProvider,
                               progress: @escaping (LookAlikeScanner.Progress, Double?) -> Void)
    async -> [ScanModeGolden] {
    switch mode {
    case .burst:
        let candidates = cluster(photos, gapSec: 3.0, sizeTol: 0.10, maxSpan: 30.0)
        let verified = await LookAlikeScanner.verifyByContent(
            candidates, provider: provider, maxDistance: 14, progress: progress)
        let indices = verified.indices.filter { verified[$0].spread <= 6 }
        let spreads = await LookAlikeScanner.featureSpreads(
            indices.map { verified[$0].photos.map(\.uuid) }, provider: provider
        ) { done, total, loaded in
            progress(.confirming(done, total, loaded: loaded), total > 0 ? Double(done) / Double(total) : nil)
        }
        var confident = Set<Int>()
        for (offset, index) in indices.enumerated() {
            if let spread = spreads[offset], spread <= 0.10 { confident.insert(index) }
        }
        return burstGolden(verified, confident)
    case .lookAlikes:
        return idGolden(await LookAlikeScanner.scan(
            itemIdentifiers: photos.map(\.uuid), provider: provider, progress: progress))
    case .similarSets:
        return idGolden(await LookAlikeScanner.scan(
            itemIdentifiers: photos.map(\.uuid), provider: provider,
            dHashDistance: 14, featureDistance: 0.45, progress: progress))
    }
}

/// Calibrate a deterministic sweep against the machine's actual Vision model.
/// Select inside the band, away from both cutoffs; failure to realize the band
/// fails the fixture check. Unavailable inference is reported as skipped below.
private func calibratedTint(seed: UInt64, label: String) async -> CGImage {
    let base = scanModeImage(seed: seed)
    guard visionInferenceAvailable else { return scanModeImage(seed: seed, tint: 0.5) }
    for step in 1...20 {
        let tint = Double(step) / 20
        let candidate = scanModeImage(seed: seed, tint: tint)
        let a = "calibrate-\(label)-\(step)-a", b = "calibrate-\(label)-\(step)-b"
        let provider = ScanModeImages([a: base, b: candidate])
        let hashes = await LookAlikeScanner.dHashesPublic([a, b], provider: provider)
        let spreads = await LookAlikeScanner.featureSpreads([[a, b]], provider: provider) { _, _, _ in }
        if let ha = hashes[a], let hb = hashes[b], hamming(ha, hb) <= 6,
           let spread = spreads[0], spread > 0.20, spread < 0.35 {
            print("  calibration \(label): tint=\(tint), dHash=\(hamming(ha, hb)), feature=\(spread)")
            return candidate
        }
    }
    checkNeedsVision(false, "scan modes: \(label) tint sweep realizes the feature-only separation band")
    return scanModeImage(seed: seed, tint: 0.5)
}

func checkScanModes() async {
    print("Shared scan modes: thresholds, calibrated golden, and Photos parity")
    check(ScanMode.allCases.map(\.rawValue) == ["burst", "lookAlikes", "similarSets"],
          "scan modes: persisted raw values remain stable")
    check(PhotoLibrarySession.ScanKind(rawValue: "similarSets") == ScanMode.similarSets,
          "scan modes: Photos ScanKind remains a source-compatible alias")
    check(ScanMode.Burst.gapSec == 3.0 && ScanMode.Burst.sizeTol == 0.10
          && ScanMode.Burst.maxSpan == 30.0 && ScanMode.Burst.confidentSpread == 6
          && ScanMode.burst.dHashDistance == 14 && ScanMode.burst.featureDistance == 0.10,
          "scan modes: burst thresholds equal the base literals")
    check(ScanMode.lookAlikes.dHashDistance == 8 && ScanMode.lookAlikes.featureDistance == 0.15
          && ScanMode.similarSets.dHashDistance == 14 && ScanMode.similarSets.featureDistance == 0.45
          && ScanMode.maxCluster == 80, "scan modes: cross-time thresholds equal the base literals")

    await LookAlikeScanner.clearCache()
    let uncertain = await calibratedTint(seed: 22, label: "uncertain")
    let similar = await calibratedTint(seed: 66, label: "similar-only")
    let provider = ScanModeImages([
        "burst-a": scanModeImage(seed: 11), "burst-b": scanModeImage(seed: 11),
        "uncertain-a": scanModeImage(seed: 22), "uncertain-b": uncertain,
        "split-a": scanModeImage(seed: 33), "split-b": scanModeImage(seed: 44),
        "distant-a": scanModeImage(seed: 55), "distant-b": scanModeImage(seed: 55),
        "similar-a": scanModeImage(seed: 66), "similar-b": similar,
        "single-a": scanModeImage(seed: 77), "single-b": scanModeImage(seed: 88),
    ])
    let captures: [(String, Double)] = [
        ("burst-a", 0), ("burst-b", 1), ("uncertain-a", 100), ("uncertain-b", 101),
        ("split-a", 200), ("split-b", 201), ("distant-a", 300), ("distant-b", 400),
        ("similar-a", 500), ("similar-b", 600), ("single-a", 700), ("single-b", 800),
    ]
    let photos = captures.map { id, time in
        Photo(uuid: id, filename: id, takenAt: time, width: 180, height: 160,
              size: 2_000_000, uti: "public.png")
    }
    let ids = photos.map(\.uuid)
    await LookAlikeScanner.clearCache()
    let hashes = await LookAlikeScanner.dHashesPublic(ids, provider: provider)
    let pairs = [["burst-a", "burst-b"], ["uncertain-a", "uncertain-b"],
                 ["split-a", "split-b"], ["distant-a", "distant-b"], ["similar-a", "similar-b"]]
    let spreads = await LookAlikeScanner.featureSpreads(pairs, provider: provider) { _, _, _ in }
    for (index, pair) in pairs.enumerated() {
        let distance = hashes[pair[0]].flatMap { a in hashes[pair[1]].map { hamming(a, $0) } }
        print("  fixture \(pair.joined(separator: "/")): dHash=\(distance.map(String.init) ?? "unavailable"), feature=\(spreads[index].map { String($0) } ?? "unavailable")")
        check(distance != nil && (index == 2 ? distance! > 14 : distance! <= 6),
              "scan modes: \(pair[0]) measured dHash band")
        checkNeedsVision(spreads[index] != nil, "scan modes: \(pair[0]) has a measured feature distance")
    }
    checkNeedsVision(spreads[0].map { $0 <= 0.10 } == true && spreads[3].map { $0 <= 0.15 } == true,
                     "scan modes: identical and far-apart copies meet their feature bands")
    checkNeedsVision(spreads[1].map { $0 > 0.15 && $0 <= 0.45 } == true
                     && spreads[4].map { $0 > 0.15 && $0 <= 0.45 } == true,
                     "scan modes: uncertain burst and similar-only pair are outside look-alikes")
    let families = [["burst-a", "burst-b"], ["uncertain-a", "uncertain-b"], ["split-a"], ["split-b"],
                    ["distant-a", "distant-b"], ["similar-a", "similar-b"], ["single-a"], ["single-b"]]
    var crossDistances: [Int] = []
    for (index, family) in families.enumerated() {
        for other in families.dropFirst(index + 1) {
            for a in family { for b in other {
                if let ha = hashes[a], let hb = hashes[b] { crossDistances.append(hamming(ha, hb)) }
            } }
        }
    }
    check(crossDistances.count == 62 && crossDistances.allSatisfy { $0 > 14 },
          "scan modes: all unrelated fixture families remain outside dHash recall")
    print("  fixture unrelated-family minimum dHash=\(crossDistances.min() ?? -1)")

    let goldens: [ScanMode: [ScanModeGolden]] = [
        .burst: [ScanModeGolden(["burst-a", "burst-b"], true), ScanModeGolden(["uncertain-a", "uncertain-b"])],
        .lookAlikes: [ScanModeGolden(["burst-a", "burst-b"]), ScanModeGolden(["distant-a", "distant-b"])],
        .similarSets: [ScanModeGolden(["burst-a", "burst-b"]), ScanModeGolden(["distant-a", "distant-b"]),
                       ScanModeGolden(["similar-a", "similar-b"]), ScanModeGolden(["uncertain-a", "uncertain-b"])],
    ]
    for mode in ScanMode.allCases {
        await LookAlikeScanner.clearCache()
        var referenceEvents: [ScanModeEvent] = []
        let reference = await referenceScanMode(mode, photos: photos, provider: provider) {
            referenceEvents.append(ScanModeEvent($0, $1))
        }
        await LookAlikeScanner.clearCache()
        var events: [ScanModeEvent] = []
        let progress: (LookAlikeScanner.Progress, Double?) -> Void = { events.append(ScanModeEvent($0, $1)) }
        let result: [ScanModeGolden]
        if mode == .burst {
            let candidates = ScanMode.Burst.candidates(photos)
            check(idGolden(candidates.map { $0.map(\.uuid) }) == idGolden([
                ["burst-a", "burst-b"], ["uncertain-a", "uncertain-b"], ["split-a", "split-b"]]),
                  "scan modes: burst candidates use capture facts and exclude far-apart pairs")
            let verified = await ScanMode.Burst.verifyContent(candidates, provider: provider, progress: progress)
            check(idGolden(verified.map { $0.photos.map(\.uuid) }) == idGolden([
                ["burst-a", "burst-b"], ["uncertain-a", "uncertain-b"]]),
                  "scan modes: content verification splits the time-adjacent unrelated pair")
            let confident = await ScanMode.Burst.confidentIndices(verified, provider: provider, progress: progress)
            result = burstGolden(verified, confident)
        } else {
            result = idGolden(await mode.scan(itemIdentifiers: ids, provider: provider, progress: progress))
        }
        checkNeedsVision(result == reference, "scan modes: \(mode.rawValue) equals the literal base comparison")
        checkNeedsVision(result == goldens[mode]!, "scan modes: \(mode.rawValue) equals the recorded non-empty golden")
        checkNeedsVision(reference == goldens[mode]!, "scan modes: base \(mode.rawValue) equals the recorded golden")
        check(events == referenceEvents, "scan modes: \(mode.rawValue) forwards every progress event and fraction")
        if mode == .lookAlikes || mode == .similarSets {
            checkNeedsVision(result.contains(ScanModeGolden(["similar-a", "similar-b"])) == (mode == .similarSets),
                             "scan modes: similar-only pair membership in \(mode.rawValue)")
        }
    }

    // A source can stop after verification without requesting neural images.
    await LookAlikeScanner.clearCache()
    let staged = ScanModeImages(["burst-a": scanModeImage(seed: 11), "burst-b": scanModeImage(seed: 11)])
    _ = await ScanMode.Burst.verifyContent(ScanMode.Burst.candidates(Array(photos.prefix(2))),
                                          provider: staged) { _, _ in }
    let profiles = await staged.profiles
    check(profiles == [.dHash, .dHash], "scan modes: stopping after content verification never starts the neural gate")

    for mode in [ScanMode.lookAlikes, .similarSets] {
        await LookAlikeScanner.clearCache()
        let noisy = Dictionary(uniqueKeysWithValues: (0..<81).map { ("noise-\($0)", scanModeImage(seed: 11)) })
        var events: [ScanModeEvent] = []
        let groups = await mode.scan(itemIdentifiers: noisy.keys.sorted(), provider: ScanModeImages(noisy)) {
            events.append(ScanModeEvent($0, $1))
        }
        check(groups.isEmpty && events.last == ScanModeEvent(.skippedClusters(1), nil),
              "scan modes: \(mode.rawValue) forwards oversized-cluster notice for camera consumers")
    }
    await LookAlikeScanner.clearCache()
}
