import Foundation
import Photos
import Vision
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore
#if os(macOS)
import AppKit   // NSImage — PHImageManager's completion type on macOS
#endif

// Live-machine harness: exercises the REAL PhotoKit / Vision / byte-gate paths
// against throwaway assets it generates and imports itself. It never touches
// existing photos. All verdict logic (predicates, keeper, suggestions) is
// imported from SnapsiftCore — the real thing; only the thin XPC plumbing is
// mirrored inline (the app's OriginalHasher/PhotoKitSyncLane live in the app
// executable target and aren't importable from here).
//
//   swift run SnapsiftLiveTests            import + verify (non-destructive)
//   swift run SnapsiftLiveTests --delete   … then delete the test assets
//                                          (system confirmation dialog — click it)
//
// Exit code: 0 = all checks passed.

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print(cond ? "  ✓ \(label)" : "  ✗ \(label)")
    if !cond { failures += 1 }
}
func die(_ msg: String) -> Never {
    print("❌ \(msg)")
    exit(2)
}

// ── deterministic test images ────────────────────────────────────────────────

/// Render a deterministic RGB pattern; `seed` varies the pattern.
func renderImage(width: Int, height: Int, seed: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in stride(from: 0, to: height, by: 8) {
        for x in stride(from: 0, to: width, by: 8) {
            let v = Double((x * 31 + y * 17 + seed * 97) % 255) / 255.0
            ctx.setFillColor(CGColor(srgbRed: v, green: (v * 0.5 + 0.2), blue: 1 - v, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
        }
    }
    return ctx.makeImage()!
}

func writeJPEG(_ image: CGImage, to url: URL, quality: Double) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { die("couldn't write \(url.lastPathComponent)") }
}

// ── thin mirrors of the app's plumbing ───────────────────────────────────────

/// SHA-256 of the primary original resource — same semantics as the app's
/// OriginalHasher (local only, no network, multi-resource → nil).
func sha256(asset: PHAsset) async -> String? {
    if asset.mediaSubtypes.contains(.photoLive) { return nil }
    let resources = PHAssetResource.assetResources(for: asset)
    guard resources.filter({ $0.type != .adjustmentData }).count <= 1 else { return nil }
    guard let res = resources.first(where: { $0.type == .photo }) ?? resources.first else { return nil }
    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = false
    final class Box: @unchecked Sendable {
        var hasher = SHA256()
        let lock = NSLock()
    }
    let box = Box()
    return await withCheckedContinuation { cont in
        PHAssetResourceManager.default().requestData(
            for: res, options: opts,
            dataReceivedHandler: { d in box.lock.lock(); box.hasher.update(data: d); box.lock.unlock() },
            completionHandler: { error in
                if error == nil {
                    box.lock.lock()
                    let hex = box.hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    box.lock.unlock()
                    cont.resume(returning: hex)
                } else {
                    cont.resume(returning: nil)
                }
            })
    }
}

/// Request a bitmap for an asset (synchronous PhotoKit image request).
func bitmap(asset: PHAsset, edge: CGFloat) async -> CGImage? {
    let opts = PHImageRequestOptions()
    opts.isNetworkAccessAllowed = false
    opts.deliveryMode = .highQualityFormat
    opts.isSynchronous = false
    return await withCheckedContinuation { cont in
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: edge, height: edge),
            contentMode: .aspectFit, options: opts) { img, _ in
            #if os(macOS)
            cont.resume(returning: img?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #else
            cont.resume(returning: img?.cgImage)
            #endif
        }
    }
}

/// 9×8 grayscale pixels → SnapsiftCore.dHash (same shape the app feeds it).
func dHashOf(_ image: CGImage) -> UInt64 {
    let w = 9, h = 8
    var pixels = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return dHash(grayRowMajor: pixels.map(Int.init))
}

func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
    let req = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: image)
    try? handler.perform([req])
    return req.results?.first as? VNFeaturePrintObservation
}

/// Mirror of the wedge-proof lane's shape: run one sync PhotoKit metadata call
/// on a dedicated queue racing a timeout. Verifies the daemon answers promptly.
func timedSyncXPC(asset: PHAsset, timeout: TimeInterval) -> Int? {
    let sem = DispatchSemaphore(value: 0)
    var count: Int?
    DispatchQueue(label: "livetest-lane").async {
        count = PHAssetResource.assetResources(for: asset).count
        sem.signal()
    }
    return sem.wait(timeout: .now() + timeout) == .success ? count : nil
}

// ── main ─────────────────────────────────────────────────────────────────────

setbuf(stdout, nil)   // unbuffered: progress shows live even if a call hangs

let wantDelete = CommandLine.arguments.contains("--delete")

let sema = DispatchSemaphore(value: 0)
Task {
    print("Photos authorization")
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized else { die("Photos access not granted (status \(status.rawValue)) — click the TCC prompt and rerun") }
    print("  ✓ authorized (readWrite)")

    // 1. Generate the test set.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapsift-livetest-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let imgA = renderImage(width: 512, height: 512, seed: 1)
    let imgB = renderImage(width: 600, height: 400, seed: 7)   // distinct + different dims
    let urlA      = dir.appendingPathComponent("A.jpg")
    let urlACopy  = dir.appendingPathComponent("A-copy.jpg")
    let urlAReenc = dir.appendingPathComponent("A-reenc.jpg")
    let urlB      = dir.appendingPathComponent("B.jpg")
    writeJPEG(imgA, to: urlA, quality: 0.9)
    try! FileManager.default.copyItem(at: urlA, to: urlACopy)           // byte-identical
    let reloaded = CGImageSourceCreateImageAtIndex(
        CGImageSourceCreateWithURL(urlA as CFURL, nil)!, 0, nil)!
    writeJPEG(reloaded, to: urlAReenc, quality: 0.72)                   // same pixels, new bytes
    writeJPEG(imgB, to: urlB, quality: 0.9)
    check(try! Data(contentsOf: urlA) == Data(contentsOf: urlACopy), "fixture: copy is byte-identical")
    check(try! Data(contentsOf: urlA) != Data(contentsOf: urlAReenc), "fixture: re-encode differs in bytes")

    // 2. Import into a dedicated album.
    let albumTitle = "snapsift-livetest"
    var assetIDs: [String] = []
    var albumID: String?
    do {
        try await PHPhotoLibrary.shared().performChanges {
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            albumID = album.placeholderForCreatedAssetCollection.localIdentifier
            var placeholders: [PHObjectPlaceholder] = []
            for url in [urlA, urlACopy, urlAReenc, urlB] {
                guard let req = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url),
                      let ph = req.placeholderForCreatedAsset else { continue }
                placeholders.append(ph)
            }
            assetIDs = placeholders.map(\.localIdentifier)
            album.addAssets(placeholders as NSFastEnumeration)
        }
    } catch { die("import failed: \(error)") }
    check(assetIDs.count == 4, "imported 4 throwaway assets into album '\(albumTitle)'")

    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
    var byID: [String: PHAsset] = [:]
    fetch.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
    guard byID.count == 4,
          let aA = byID[assetIDs[0]], let aCopy = byID[assetIDs[1]],
          let aReenc = byID[assetIDs[2]], let aB = byID[assetIDs[3]] else {
        die("imported assets didn't resolve back")
    }
    check(true, "all 4 resolve via fetchAssets(withLocalIdentifiers:)")

    // 3. Byte gate — the doctrine's final arbiter.
    print("Byte gate (SHA-256 over originals)")
    let dA = await sha256(asset: aA), dCopy = await sha256(asset: aCopy)
    let dReenc = await sha256(asset: aReenc), dB = await sha256(asset: aB)
    check(dA != nil && dA == dCopy, "byte-identical pair digests EQUAL (would qualify as exact)")
    check(dReenc != nil && dReenc != dA, "re-encoded copy digests DIFFER (re-save can NEVER be exact)")
    check(dB != nil && dB != dA, "distinct image digests differ")

    // 4. Perceptual gates + Core predicate, on real PhotoKit bitmaps.
    print("Perceptual gates (real bitmaps through Core predicates)")
    guard let bmA = await bitmap(asset: aA, edge: 512),
          let bmCopy = await bitmap(asset: aCopy, edge: 512),
          let bmReenc = await bitmap(asset: aReenc, edge: 512),
          let bmB = await bitmap(asset: aB, edge: 512) else { die("bitmap requests failed") }
    let hamCopy = hamming(dHashOf(bmA), dHashOf(bmCopy))
    let hamB = hamming(dHashOf(bmA), dHashOf(bmB))
    check(hamCopy == 0, "dHash(A, byte-copy) hamming == 0 (got \(hamCopy))")
    check(hamB > ExactDuplicatePredicate.hammingThreshold, "dHash(A, distinct) hamming > 0 (got \(hamB))")
    var featCopy: Float = .infinity, featReenc: Float = .infinity, featB: Float = .infinity
    if let fA = featurePrint(bmA), let fC = featurePrint(bmCopy),
       let fR = featurePrint(bmReenc), let fB = featurePrint(bmB) {
        try? fA.computeDistance(&featCopy, to: fC)
        try? fA.computeDistance(&featReenc, to: fR)
        try? fA.computeDistance(&featB, to: fB)
    }
    check(featCopy <= ExactDuplicatePredicate.featureThreshold,
          "featureprint(A, copy) ≤ \(ExactDuplicatePredicate.featureThreshold) (got \(featCopy))")
    check(featB > ExactDuplicatePredicate.featureThreshold,
          "featureprint(A, distinct) above the exact bar (got \(featB))")
    check(ExactDuplicatePredicate.isExactDuplicate(hammingDistance: hamCopy, featureDistance: featCopy, sameSize: true),
          "Core predicate: byte-copy pair IS exact")
    check(!ExactDuplicatePredicate.isExactDuplicate(hammingDistance: hamB, featureDistance: featB, sameSize: false),
          "Core predicate: distinct pair is NOT exact")
    // The re-encode LOOKS exact perceptually — only the byte gate separates it.
    let reencLooksExact = ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: hamming(dHashOf(bmA), dHashOf(bmReenc)),
        featureDistance: featReenc, sameSize: true)
    print("  · re-encode passes perceptual gates: \(reencLooksExact) — byte gate (digest mismatch above) is what protects it")

    // 5. Protection: favorite one frame, prove it never enters suggestions.
    print("Protection sweep (real favorite flag)")
    try? await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest(for: aCopy).isFavorite = true
    }
    let refetched = PHAsset.fetchAssets(withLocalIdentifiers: [aCopy.localIdentifier], options: nil)
    let favNow = refetched.firstObject?.isFavorite ?? false
    check(favNow, "favorite write round-trips through PhotoKit")
    func mirror(_ a: PHAsset, _ n: Int, fav: Bool) -> Photo {
        Photo(uuid: a.localIdentifier, filename: "T\(n).jpg", takenAt: 0,
              width: a.pixelWidth, height: a.pixelHeight, size: 100_000,
              uti: "public.jpeg", favorite: fav, quality: 0,
              edited: false, isDocument: false, sharpness: 0, originalCamera: false)
    }
    let group = [mirror(aA, 1, fav: false), mirror(aCopy, 2, fav: favNow)]
    let suggested = exactDuplicateSuggestions(group).map(\.uuid)
    check(!suggested.contains(aCopy.localIdentifier), "favorited frame NEVER suggested for deletion")
    check(suggested.contains(aA.localIdentifier) == (keeper(group).uuid != aA.localIdentifier),
          "non-keeper unprotected frame is the only suggestion")

    // 6. Sync-XPC health probe (the wedge class the lane guards against).
    let resCount = timedSyncXPC(asset: aA, timeout: 10)
    check(resCount != nil, "sync assetResources answered within 10 s (photolibraryd healthy; count=\(resCount ?? -1))")

    // 7. Optional destructive pass — throwaway assets only, recoverable 30 days.
    if wantDelete {
        print("Destructive pass (test assets only → Recently Deleted)")
        print("  ⚠️ CLICK THE SYSTEM CONFIRMATION DIALOG NOW")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([aA, aCopy, aReenc, aB] as NSFastEnumeration)
                if let albumID,
                   let album = PHAssetCollection.fetchAssetCollections(
                       withLocalIdentifiers: [albumID], options: nil).firstObject {
                    PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSFastEnumeration)
                }
            }
            let after = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            check(after.count == 0, "all 4 test assets gone from the library (in Recently Deleted)")
        } catch {
            check(false, "delete failed/cancelled: \(error.localizedDescription)")
        }
    } else {
        print("  · non-destructive run — test assets left in album '\(albumTitle)'; rerun with --delete to clean up")
    }

    print(failures == 0 ? "\n✅ live harness: all checks passed" : "\n❌ \(failures) failure(s)")
    sema.signal()
}
sema.wait()
exit(failures == 0 ? 0 : 1)
