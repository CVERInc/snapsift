import Foundation
import CoreGraphics
import Photos
import Vision
import SnapsiftCore
@testable import SnapsiftPhotoKit
@testable import SnapsiftVision

private final class CancelTestAsset: PHAsset, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id; super.init() }
    override var localIdentifier: String { id }
    override var isFavorite: Bool { false }
}

private func cancelTestFeaturePrint(cache: isolated LookAlikeScanner.Cache) throws -> Bool {
    // The inherited default initializer returns nil on some Vision runtimes.
    // Drain the request's temporary ownership before testing cache retention.
    try autoreleasepool {
        guard let context = CGContext(data: nil, width: 64, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { return false }
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { return false }
        cache.setFeaturePrint(observation, for: "scan-only")
        return true
    }
}

@MainActor
func checkCancelledPhotoScanReleasesWorkingSet() async {
    print("Cancelled Photos scan releases working set")
    for restorePrevious in [false, true] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapsift-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = PhotoLibraryStorage(directory: root)
        let session = PhotoLibrarySession(storage: storage, albumTitles: testAlbumTitles())
        let restoredAssets = Dictionary(uniqueKeysWithValues: (1...4).map {
            ("U\($0)", CancelTestAsset("U\($0)") as PHAsset)
        })
        session.effects.fetchSnapshotAssets = { ids in
            restoredAssets.filter { ids.contains($0.key) }
        }
        session.effects.editedFallback = { _ in false }
        if restorePrevious {
            let snapshot = ScanSnapshot(kind: "burst", sourceID: nil, timestamp: Date(), changeToken: nil,
                groups: [.init(photos: [ph(1, 0), ph(2, 1)], keeperID: "U1", rejected: ["U2"],
                               autoSeeded: [], confidentDupe: false, exact: false)],
                categories: [.init(label: "Saved set", photos: [ph(3, 2), ph(4, 3)])])
            check(ScanSnapshotStore(url: storage.snapshotURL).saveSync(snapshot),
                  "cancel restore: previous review snapshot saved")
        }

        check(session.beginScan(.burst), "cancel cleanup: scan begins")
        weak var scanOnlyAsset: PHAsset?
        do {
            let asset = CancelTestAsset("scan-only")
            scanOnlyAsset = asset
            session.photoKitImages = session.makeImageProvider(assetsByID: ["scan-only": asset])
        }
        session.groups = [ReviewGroup(photos: [ph(9, 0), ph(10, 1)], keeperID: "U9")]
        await LookAlikeScanner.clearCache()
        // Without Vision inference (GitHub's macOS runners) the feature-print
        // checks are skipped; the asset map and other caches are still checked.
        if visionInferenceAvailable {
            do {
                guard try await cancelTestFeaturePrint(cache: LookAlikeScanner.cache) else {
                    check(false, "cancel cleanup: Vision fixture produces a feature print")
                    continue
                }
            } catch {
                check(false, "cancel cleanup: Vision fixture produces a feature print (\(error))")
                continue
            }
        } else {
            checkNeedsVision(false, "cancel cleanup: Vision fixture produces a feature print")
        }
        await LookAlikeScanner.cache.setHash(42, for: "scan-only")
        await LookAlikeScanner.cache.markFailedHash("unreadable")
        await LookAlikeScanner.cache.markFailedPrint("unreadable")
        let retainsAsset = scanOnlyAsset != nil
            && session.photoKitImages.itemIdentifiers == ["scan-only"]
            && session.asset(for: "scan-only") === scanOnlyAsset
        let retainsPrint = await LookAlikeScanner.cache.featurePrint("scan-only") != nil
        check(retainsAsset, "cancel cleanup: fixture provider retains scan-only asset")
        checkNeedsVision(retainsPrint, "cancel cleanup: fixture cache retains Vision print")
        guard retainsAsset, retainsPrint || !visionInferenceAvailable else { continue }
        session.cancelScan()
        check(await session.bailIfCancelled(), "cancel cleanup: pipeline observes cancellation")
        check(scanOnlyAsset == nil && session.asset(for: "scan-only") == nil,
              "cancel cleanup: whole-library asset map released")
        let cachedPrintReleased = await LookAlikeScanner.cache.featurePrint("scan-only") == nil
        checkNeedsVision(cachedPrintReleased, "cancel cleanup: Vision feature-print cache entry released")
        let hash = await LookAlikeScanner.cache.hash("scan-only")
        let failedHash = await LookAlikeScanner.cache.didFailHash("unreadable")
        let failedPrint = await LookAlikeScanner.cache.didFailPrint("unreadable")
        check(hash == nil && !failedHash && !failedPrint, "cancel cleanup: hash and negative caches released")
        check(!session.isScanning, "cancel cleanup: scan no longer busy")
        if restorePrevious {
            for _ in 0..<200 where session.groups.isEmpty {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(session.groups.count == 1 && session.groups.first?.keeperID == "U1"
                  && session.groups.first?.rejected == ["U2"],
                  "cancel restore: previous keeper and user rejection survive")
            check(session.categories.flatMap { $0.photos.map(\.uuid) } == ["U3", "U4"],
                  "cancel restore: previous category survives")
            check(session.photoKitImages.itemIdentifiers == ["U1", "U2", "U3", "U4"],
                  "cancel restore: provider retains all restored group and category members")
            check(session.asset(for: "U1") === restoredAssets["U1"]
                  && session.asset(for: "U3") === restoredAssets["U3"],
                  "cancel restore: restored assets remain available to consumers")
            if let group = session.groups.first {
                session.keepAll(group: group.id)
                check(session.groups[0].rejected.isEmpty, "cancel restore: restored review decisions remain editable")
                session.flushSnapshotSync()
            }
        } else {
            check(session.photoKitImages.itemIdentifiers.isEmpty && session.groups.isEmpty,
                  "cancel cleanup: no previous session leaves no scan assets or partial groups")
        }
    }
}
