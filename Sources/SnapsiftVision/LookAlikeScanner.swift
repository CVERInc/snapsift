import Foundation
import CoreGraphics
import Vision
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
public enum LookAlikeScanner {

    public enum Progress {
        case hashing(Int, Int)
        case confirming(Int, Int, loaded: Int)
        case skippedClusters(Int)
        case verifying(Int, Int)
    }

    // MARK: - per-scan compute cache

    /// dHashes and feature prints survive across the passes of ONE scan
    /// (burst/look-alike scan → confident gate → exact-duplicate pass), so the
    /// same asset is never hashed or feature-printed twice in a pipeline.
    /// Cleared at the start of every new scan — pixels can change between scans
    /// (edits, rotation saves), so verdicts must never outlive the session.
    private actor Cache {
        private var hashes: [String: UInt64] = [:]
        private var prints: [String: VNFeaturePrintObservation] = [:]
        // Negative results: assets whose thumbnail couldn't be read THIS scan.
        // Pixels don't change within a scan, so an unreadable thumbnail stays
        // unreadable — without this, the exact-duplicate pass re-requested every
        // already-failed member and re-paid the full 2 s timeout, serially, in a
        // dead tail after the scan looked done.
        private var failedHash: Set<String> = []
        private var failedPrint: Set<String> = []
        func hash(_ id: String) -> UInt64? { hashes[id] }
        func setHash(_ h: UInt64, for id: String) { hashes[id] = h }
        func didFailHash(_ id: String) -> Bool { failedHash.contains(id) }
        func markFailedHash(_ id: String) { failedHash.insert(id) }
        func featurePrint(_ id: String) -> VNFeaturePrintObservation? { prints[id] }
        func setFeaturePrint(_ p: VNFeaturePrintObservation, for id: String) { prints[id] = p }
        func didFailPrint(_ id: String) -> Bool { failedPrint.contains(id) }
        func markFailedPrint(_ id: String) { failedPrint.insert(id) }
        func clear() { hashes = [:]; prints = [:]; failedHash = []; failedPrint = [] }
    }
    private static let cache = Cache()

    /// Must be called when a new scan begins (LibraryModel does this).
    public static func clearCache() async { await cache.clear() }

    public static func scan(itemIdentifiers: [String],
                           provider: any ImageProvider,
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
                           progress: @escaping (Progress, Double?) -> Void) async -> [[String]] {

        // Stage 1 — dHash all thumbnails, 8-wide (timeout-guarded). Serial reads
        // over a six-figure library were a bottleneck of their own.
        // The fraction is scan-internal 0…1: hashing 0…0.6, confirming 0.6…1.
        let hashes = await dHashes(itemIdentifiers, provider: provider) { done, total in
            progress(.hashing(done, total),
                     total > 0 ? 0.6 * Double(done) / Double(total) : nil)
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
        // trickling one small cluster at a time, and the provider's per-image
        // timeout means a stuck thumbnail can never stall the batch.
        let ids = Array(Set(surviving.flatMap { $0 }))
        let prints = await featurePrints(ids, provider: provider) { done, loaded in
            progress(.confirming(done, ids.count, loaded: loaded),
                     ids.isEmpty ? 1 : 0.6 + 0.4 * Double(done) / Double(ids.count))
        }

        var confirmed: [[String]] = []
        for cand in surviving {
            let p = cand.compactMap { id in prints[id].map { (id, $0) } }
            for group in unionByDistance(p, maxDistance: featureDistance) where group.count >= 2 {
                confirmed.append(group)
            }
        }
        if skipped > 0 { progress(.skippedClusters(skipped), nil) }
        return confirmed
    }

    /// Hash specific item IDs, sharing the current scan's success/failure cache.
    public static func dHashesPublic(_ ids: [String],
                                     provider: any ImageProvider) async -> [String: UInt64] {
        await dHashes(ids, provider: provider) { _, _ in }
    }

    /// dHash a set of items with bounded concurrency (provider timeout per
    /// thumbnail). Unreadable items are simply absent from the result.
    private static func dHashes(_ ids: [String],
                               provider: any ImageProvider,
                                progress: @escaping (Int, Int) -> Void) async -> [String: UInt64] {
        // Serve cache hits first; only compute what this scan hasn't seen yet.
        // Assets already known unreadable this scan are skipped, not re-fetched.
        var out: [String: UInt64] = [:]
        var missing: [String] = []
        for id in ids {
            if let h = await cache.hash(id) { out[id] = h }
            else if await cache.didFailHash(id) { continue }   // known unreadable — don't re-pay the timeout
            else { missing.append(id) }
        }
        var done = out.count
        await withTaskGroup(of: (String, UInt64?).self) { group in
            var next = 0
            func add() {
                // Cooperative cancellation: stop feeding new work; in-flight
                // requests drain naturally and the partial result is discarded
                // by the caller.
                while !Task.isCancelled, next < missing.count {
                    let id = missing[next]; next += 1
                    guard provider.itemIdentifiers.contains(id) else { continue }
                    group.addTask {
                        if let px = await grayPixels9x8(id, provider) { return (id, dHash(grayRowMajor: px)) }
                        return (id, nil)
                    }
                    return
                }
            }
            for _ in 0..<featureConcurrency { add() }
            for await (id, h) in group {
                if let h {
                    out[id] = h
                    await cache.setHash(h, for: id)
                } else {
                    await cache.markFailedHash(id)   // remember so we never re-fetch it this scan
                }
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
                                     provider: any ImageProvider,
                                      progress: @escaping (Int, Int) -> Void)
        async -> [String: VNFeaturePrintObservation] {
        // Serve cache hits first; only compute what this scan hasn't seen yet.
        // Assets already known unreadable this scan are skipped, not re-fetched.
        var out: [String: VNFeaturePrintObservation] = [:]
        var missing: [String] = []
        for id in ids {
            if let fp = await cache.featurePrint(id) { out[id] = fp }
            else if await cache.didFailPrint(id) { continue }   // known unreadable — don't re-pay the timeout
            else { missing.append(id) }
        }
        var done = out.count, loaded = out.count
        await withTaskGroup(of: (String, VNFeaturePrintObservation?).self) { group in
            var next = 0
            func add() {
                while !Task.isCancelled, next < missing.count {   // cooperative cancel
                    let id = missing[next]; next += 1
                    guard provider.itemIdentifiers.contains(id) else { continue }   // unknown id — skip
                    group.addTask { (id, await featurePrint(id, provider)) }
                    return
                }
            }
            for _ in 0..<featureConcurrency { add() }
            for await (id, fp) in group {
                if let fp {
                    out[id] = fp; loaded += 1
                    await cache.setFeaturePrint(fp, for: id)
                } else {
                    await cache.markFailedPrint(id)   // remember so we never re-fetch it this scan
                }
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
    public static func featureSpreads(_ clusters: [[String]],
                                     provider: any ImageProvider,
                               progress: @escaping (_ done: Int, _ total: Int, _ loaded: Int) -> Void)
        async -> [Float?] {
        let ids = Array(Set(clusters.flatMap { $0 }))
        let prints = await featurePrints(ids, provider: provider) { done, loaded in
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
    public struct VerifiedCluster { public let photos: [Photo]; public let spread: Int }

    public static func verifyByContent(_ clusters: [[Photo]],
                                      provider: any ImageProvider,
                                       maxDistance: Int,
                                progress: @escaping (Progress, Double?) -> Void) async -> [VerifiedCluster] {
        // dHash every clustered frame up front, 8-wide — the only I/O here. The
        // re-split below is then pure in-memory work. (Was a serial per-frame loop
        // that stalled 2s on each thumbnail Photos couldn't serve locally.)
        let ids = Array(Set(clusters.flatMap { $0.map(\.uuid) }))
        let hashes = await dHashes(ids, provider: provider) { done, total in
            progress(.verifying(done, total),
                     total > 0 ? Double(done) / Double(total) : nil)
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

    /// Flat 9×8 grayscale buffer for Core's dHash.
    private static func grayPixels9x8(_ id: String, _ provider: any ImageProvider) async -> [Int]? {
        guard let cg = await provider.image(for: id, profile: .dHash)
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

    private static func featurePrint(_ id: String, _ provider: any ImageProvider) async -> VNFeaturePrintObservation? {
        // 160px (down from 256): far likelier to fall within the locally cached
        // thumbnail on an iCloud-optimised library, so it returns instantly
        // instead of stalling. Plenty of detail for a near-duplicate feature print.
        guard let cg = await provider.image(for: id, profile: .featurePrint)
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
