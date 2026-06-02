import Foundation
import Photos
import Vision
import AppKit
import SnapsiftCore

/// L3 cross-time pass: find the same photo saved on different days (re-downloaded,
/// screenshotted, AirDropped back) that the time-burst scan can't see.
///
/// Two-stage so it stays tractable on a six-figure library:
///   1. dHash every thumbnail and group candidates with Core's BK-tree
///      (cheap recall, sub-quadratic) — this avoids the O(n²) trap.
///   2. Confirm each candidate cluster with Apple's neural feature print
///      (VNGenerateImageFeaturePrint + computeDistance) for precision.
/// Feature prints are only computed for assets that survive stage 1, so the
/// expensive neural step runs on a small fraction of the library.
enum LookAlikeScanner {

    static func scan(assets: [PHAsset],
                     manager: PHCachingImageManager,
                     dHashDistance: Int = 8,
                     featureDistance: Float = 0.7,
                     progress: @escaping (String) -> Void) async -> [[String]] {

        // Stage 1 — dHash all thumbnails (tiny 9×8 requests, fast).
        var items: [(UInt64, String)] = []
        items.reserveCapacity(assets.count)
        var i = 0
        for a in assets {
            if let px = await grayPixels9x8(a, manager) {
                items.append((dHash(grayRowMajor: px), a.localIdentifier))
            }
            i += 1
            if i % 500 == 0 { progress("Hashing \(i)/\(assets.count)…") }
        }
        let candidates = groupByHash(items, maxDistance: dHashDistance)

        // Stage 2 — confirm each candidate with neural feature-print distance.
        var byID: [String: PHAsset] = [:]
        for a in assets { byID[a.localIdentifier] = a }

        var confirmed: [[String]] = []
        var c = 0
        for cand in candidates {
            c += 1
            if c % 25 == 0 { progress("Confirming \(c)/\(candidates.count) candidate groups…") }
            var prints: [(String, VNFeaturePrintObservation)] = []
            for id in cand {
                if let a = byID[id], let fp = await featurePrint(a, manager) {
                    prints.append((id, fp))
                }
            }
            for group in unionByDistance(prints, maxDistance: featureDistance) where group.count >= 2 {
                confirmed.append(group)
            }
        }
        return confirmed
    }

    // MARK: - feature-print union

    private static func unionByDistance(_ prints: [(String, VNFeaturePrintObservation)],
                                        maxDistance: Float) -> [[String]] {
        let n = prints.count
        guard n >= 2 else { return [] }
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var cur = x
            while parent[cur] != r { let nx = parent[cur]; parent[cur] = r; cur = nx }
            return r
        }
        for a in 0..<n {
            for b in (a + 1)..<n {
                var d: Float = 0
                do { try prints[a].1.computeDistance(&d, to: prints[b].1) } catch { continue }
                if d <= maxDistance { parent[find(a)] = find(b) }
            }
        }
        var comp: [Int: [String]] = [:]
        for idx in 0..<n { comp[find(idx), default: []].append(prints[idx].0) }
        return Array(comp.values)
    }

    // MARK: - image helpers

    private static func cgImage(_ asset: PHAsset, _ manager: PHCachingImageManager,
                                target: CGSize, mode: PHImageContentMode) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .exact
        let img: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: mode, options: opts) { image, _ in
                cont.resume(returning: image)
            }
        }
        guard let img else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Flat 9×8 grayscale buffer for Core's dHash.
    private static func grayPixels9x8(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> [Int]? {
        guard let cg = await cgImage(asset, manager,
                                     target: CGSize(width: 9, height: 8), mode: .aspectFill)
        else { return nil }
        let w = 9, h = 8
        var data = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data.map(Int.init)
    }

    private static func featurePrint(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> VNFeaturePrintObservation? {
        guard let cg = await cgImage(asset, manager,
                                     target: CGSize(width: 256, height: 256), mode: .aspectFit)
        else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        return request.results?.first as? VNFeaturePrintObservation
    }
}
