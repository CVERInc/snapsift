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
                     t: L10n,
                     dHashDistance: Int = 8,
                     featureDistance: Float = 0.15,   // ≈0.0 for a true re-saved
                                                      // copy; 0.15 excludes merely
                                                      // similar shots (cats ≈0.3)
                     maxCluster: Int = 80,            // a stage-1 dHash cluster
                                                      // bigger than this is noise
                                                      // (solid colours, screenshots
                                                      // all colliding). Confirming
                                                      // it means thousands of neural
                                                      // prints + O(n²) — the freeze.
                     progress: @escaping (String) -> Void) async -> [[String]] {

        var byID: [String: PHAsset] = [:]
        for a in assets { byID[a.localIdentifier] = a }

        // Stage 1 — dHash all thumbnails, 8-wide (timeout-guarded). Serial reads
        // over a six-figure library were a bottleneck of their own.
        let hashes = await dHashes(assets.map(\.localIdentifier), asset: { byID[$0] },
                                   manager: manager) { done, total in
            progress(t.progHashing(done, total))
        }
        let candidates = groupByHash(hashes.map { ($0.value, $0.key) }, maxDistance: dHashDistance)

        // Stage 2 — confirm each candidate with neural feature-print distance.

        // Oversized dHash clusters are collision noise (solid colours, screenshots
        // all colliding); confirming them is the O(n²) + thousands-of-fetches
        // freeze. Drop them up front.
        let surviving = candidates.filter { $0.count <= maxCluster }
        let skipped = candidates.count - surviving.count

        // Compute every surviving member's feature print ONCE, across the whole
        // workload with bounded concurrency — this saturates the cores instead of
        // trickling one small cluster at a time, and the per-image timeout in
        // cgImage means a stuck thumbnail can never stall the batch.
        let ids = Array(Set(surviving.flatMap { $0 }))
        let prints = await featurePrints(ids, byID: byID, manager: manager) { done, loaded in
            progress(t.progConfirming(done, ids.count, loaded: loaded))
        }

        var confirmed: [[String]] = []
        for cand in surviving {
            let p = cand.compactMap { id in prints[id].map { (id, $0) } }
            for group in unionByDistance(p, maxDistance: featureDistance) where group.count >= 2 {
                confirmed.append(group)
            }
        }
        if skipped > 0 { progress(t.progSkippedClusters(skipped)) }
        return confirmed
    }

    /// Public wrapper so LibraryModel's exact-duplicate pass can hash a specific
    /// set of asset IDs without duplicating the implementation. The private
    /// `dHashes` variant uses a closure lookup; this variant takes the direct
    /// `byID` dictionary, matching the pattern used by `featureSpreads`.
    static func dHashesPublic(_ ids: [String],
                              byID: [String: PHAsset],
                              manager: PHCachingImageManager) async -> [String: UInt64] {
        await dHashes(ids, asset: { byID[$0] }, manager: manager) { _, _ in }
    }

    /// dHash a set of assets with bounded concurrency (timeout per thumbnail in
    /// cgImage). Unreadable assets are simply absent from the result.
    private static func dHashes(_ ids: [String],
                                asset: @escaping (String) -> PHAsset?,
                                manager: PHCachingImageManager,
                                progress: @escaping (Int, Int) -> Void) async -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        var done = 0
        await withTaskGroup(of: (String, UInt64?).self) { group in
            var next = 0
            func add() {
                while next < ids.count {
                    let id = ids[next]; next += 1
                    guard let a = asset(id) else { continue }
                    group.addTask {
                        if let px = await grayPixels9x8(a, manager) { return (id, dHash(grayRowMajor: px)) }
                        return (id, nil)
                    }
                    return
                }
            }
            for _ in 0..<featureConcurrency { add() }
            for await (id, h) in group {
                if let h { out[id] = h }
                done += 1
                if done % 500 == 0 { progress(done, ids.count) }
                add()
            }
        }
        progress(done, ids.count)
        return out
    }

    /// Feature-print a set of assets with bounded concurrency, reporting
    /// (processed, successfully-loaded) so the UI can show how many thumbnails
    /// were actually readable — the number that tells slow-but-working apart from
    /// can't-read-the-library.
    private static let featureConcurrency = 8
    private static func featurePrints(_ ids: [String],
                                      byID: [String: PHAsset],
                                      manager: PHCachingImageManager,
                                      progress: @escaping (Int, Int) -> Void)
        async -> [String: VNFeaturePrintObservation] {
        var out: [String: VNFeaturePrintObservation] = [:]
        var done = 0, loaded = 0
        await withTaskGroup(of: (String, VNFeaturePrintObservation?).self) { group in
            var next = 0
            func add() {
                while next < ids.count {
                    let id = ids[next]; next += 1
                    guard let a = byID[id] else { continue }   // unknown id — skip
                    group.addTask { (id, await featurePrint(a, manager)) }
                    return
                }
            }
            for _ in 0..<featureConcurrency { add() }
            for await (id, fp) in group {
                if let fp { out[id] = fp; loaded += 1 }
                done += 1
                if done % 100 == 0 { progress(done, loaded) }
                add()
            }
        }
        progress(done, loaded)
        return out
    }

    /// Max pairwise feature distance per cluster (nil if any member's thumbnail
    /// can't be read), computing each needed print once across the whole set with
    /// bounded concurrency. The burst scan's confident-gate uses this so its
    /// neural confirmation runs concurrently instead of one cluster at a time —
    /// the difference between minutes and the hour-long serial stall on a library
    /// where ~a third of thumbnails aren't locally available.
    static func featureSpreads(_ clusters: [[String]],
                               byID: [String: PHAsset],
                               manager: PHCachingImageManager,
                               progress: @escaping (_ done: Int, _ total: Int, _ loaded: Int) -> Void)
        async -> [Float?] {
        let ids = Array(Set(clusters.flatMap { $0 }))
        let prints = await featurePrints(ids, byID: byID, manager: manager) { done, loaded in
            progress(done, ids.count, loaded)
        }
        return clusters.map { cluster in
            let fps = cluster.compactMap { prints[$0] }
            guard fps.count == cluster.count else { return nil }   // any unreadable → uncertain
            var maxD: Float = 0
            for i in 0..<fps.count {
                for j in (i + 1)..<fps.count {
                    var d: Float = 0
                    do { try fps[i].computeDistance(&d, to: fps[j]) } catch { continue }
                    maxD = max(maxD, d)
                }
            }
            return maxD
        }
    }

    /// Content-verify time-burst clusters: a burst is only real if its frames
    /// actually look alike. We dHash each member and re-split the cluster by
    /// perceptual proximity, dropping frames that landed together purely by
    /// timing + dimensions (e.g. two different shots taken 2s apart). Clusters
    /// where a member's thumbnail can't be read are left untouched (we don't
    /// split on incomplete information).
    /// A content-verified cluster plus its internal perceptual spread (the max
    /// pairwise dHash distance among members). Small spread ⇒ near-identical
    /// frames (a confident, redundant burst); larger spread ⇒ the subject moved
    /// (a session the user may want to keep). `spread == Int.max` means the
    /// cluster couldn't be hashed and was left unverified.
    struct VerifiedCluster { let photos: [Photo]; let spread: Int }

    static func verifyByContent(_ clusters: [[Photo]],
                                asset: @escaping (String) -> PHAsset?,
                                manager: PHCachingImageManager,
                                maxDistance: Int,
                                t: L10n,
                                progress: @escaping (String) -> Void) async -> [VerifiedCluster] {
        // dHash every clustered frame up front, 8-wide — the only I/O here. The
        // re-split below is then pure in-memory work. (Was a serial per-frame loop
        // that stalled 2s on each thumbnail Photos couldn't serve locally.)
        let ids = Array(Set(clusters.flatMap { $0.map(\.uuid) }))
        let hashes = await dHashes(ids, asset: asset, manager: manager) { done, total in
            progress(t.progVerifying(done, total))
        }

        var out: [VerifiedCluster] = []
        for cluster in clusters {
            let hashed = cluster.compactMap { p in hashes[p.uuid].map { ($0, p) } }
            if hashed.count != cluster.count {
                out.append(VerifiedCluster(photos: cluster, spread: Int.max))  // any unreadable → uncertain
                continue
            }
            let hashByUUID = Dictionary(uniqueKeysWithValues: hashed.map { ($0.1.uuid, $0.0) })
            for sub in groupByHash(hashed, maxDistance: maxDistance) where sub.count >= 2 {
                let hs = sub.compactMap { hashByUUID[$0.uuid] }
                var spread = 0
                for i in 0..<hs.count { for j in (i + 1)..<hs.count { spread = max(spread, hamming(hs[i], hs[j])) } }
                out.append(VerifiedCluster(photos: sub.sorted { $0.takenAt < $1.takenAt }, spread: spread))
            }
        }
        return out
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

    /// One-shot continuation that resumes exactly once — whichever of the image
    /// callback or the timeout fires first wins; the loser is a no-op. This is the
    /// hard guarantee that a single non-responding `requestImage` (PhotoKit can,
    /// on an iCloud-optimised library, simply never call back) can't freeze the
    /// whole scan: after the deadline the frame is treated as unreadable and we
    /// move on. Leak-free — the continuation always resumes via the timer.
    private final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<NSImage?, Never>?
        func set(_ c: CheckedContinuation<NSImage?, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ img: NSImage?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: img)
        }
    }

    /// Seconds a single thumbnail request may take before we give up on it. With
    /// the work now running 8-wide these overlap, but a tighter bound still trims
    /// the tail spent on assets with no locally cached thumbnail.
    private static let imageTimeoutNs: UInt64 = 2_000_000_000

    private static func cgImage(_ asset: PHAsset, _ manager: PHCachingImageManager,
                                target: CGSize, mode: PHImageContentMode) async -> CGImage? {
        let opts = PHImageRequestOptions()
        // Never pull originals down from iCloud. On a library with "Optimize Mac
        // Storage", a request larger than the cached thumbnail with .fastFormat
        // just *waits* for a download it isn't allowed to do — it neither serves
        // the smaller cached image nor returns nil, so it stalls until our
        // timeout. .opportunistic instead hands back whatever is cached locally
        // *right now* (even if smaller than asked), which is exactly what dHash /
        // feature prints need. First (cached) callback wins via ImageBox.
        opts.isNetworkAccessAllowed = false
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast

        let box = ImageBox()
        let img: NSImage? = await withCheckedContinuation { cont in
            box.set(cont)
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: mode, options: opts) { image, _ in
                box.finish(image)
            }
            Task { try? await Task.sleep(nanoseconds: imageTimeoutNs); box.finish(nil) }
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

    /// Vision's `perform` is a *synchronous, thread-blocking* call. Running it
    /// directly inside the concurrent task group ran 8 of them on Swift's
    /// cooperative thread pool at once, blocking every pool thread — so the
    /// continuations and timeouts that other tasks were awaiting could never be
    /// resumed. The whole scan deadlocked (dHashing finished because it has no
    /// such blocking call; the feature-print pass wedged). Run perform on a plain
    /// GCD queue instead, off the cooperative pool, so the pool stays free.
    private static let visionQueue = DispatchQueue(label: "net.cver.snapsift.vision",
                                                   qos: .userInitiated, attributes: .concurrent)

    private static func featurePrint(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> VNFeaturePrintObservation? {
        // 160px (down from 256): far likelier to fall within the locally cached
        // thumbnail on an iCloud-optimised library, so it returns instantly
        // instead of stalling. Plenty of detail for a near-duplicate feature print.
        guard let cg = await cgImage(asset, manager,
                                     target: CGSize(width: 160, height: 160), mode: .aspectFit)
        else { return nil }
        return await withCheckedContinuation { cont in
            visionQueue.async {
                let request = VNGenerateImageFeaturePrintRequest()
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([request])
                    cont.resume(returning: request.results?.first as? VNFeaturePrintObservation)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
