import Foundation
import Photos
import Vision
import SnapsiftCore

/// On-device detection of the slice-1 protection / ranking flags for a Photo.
///
/// EVERYTHING here runs on-device with NO network access — consistent with the
/// scan path (`LookAlikeScanner` sets `isNetworkAccessAllowed = false`). False
/// positives only over-protect or reorder a keeper, which is the safe direction;
/// the #1 rule is to never mark a frame a human likely wants to keep.
///
/// Split by cost:
///   • `edited` and `originalCamera` are derived from cheap PhotoKit metadata
///     synchronously while building the Photo (no pixels needed).
///   • `isDocument` and `sharpness` need pixel access, so they run only over the
///     members of real clusters in a bounded-concurrency pass AFTER clustering —
///     never the whole library — and only matter for photos that could be
///     deleted or chosen as keeper anyway.
enum PhotoFlags {

    // MARK: - `edited` via PhotoKit — FALLBACK ONLY (sidecar unavailable)

    /// True when the user applied adjustments to this asset — PhotoKit path.
    ///
    /// We rely on the reliable PUBLIC PhotoKit signals, NOT `modificationDate !=
    /// creationDate` — iCloud sync, metadata writes (favoriting, captioning),
    /// face/scene reprocessing and library migrations all bump modificationDate
    /// without any user edit, so that heuristic would wrongly flag (here: over-
    /// protect — harmless) AND, worse, would be noise we can't trust. Instead:
    ///   1. `PHAssetResource.assetResources(for:)` contains a resource of type
    ///      `.adjustmentData` once an edit has been committed (any editor —
    ///      Photos' own crop/filter or a third-party extension writes it). This
    ///      is the canonical "this asset carries edit data" signal.
    ///   2. `PHAsset.adjustmentFormatIdentifier` (macOS 12+) is non-nil for an
    ///      edited asset — a cheap corroborating signal, OR-ed in.
    ///
    /// ⚠️ Both signals are SYNCHRONOUS XPC round-trips into photolibraryd with
    /// no timeout of their own. If the daemon restarts mid-call the reply never
    /// arrives and the calling thread wedges FOREVER — and because the fetch
    /// funnels through the one shared library CoreData queue, every later
    /// PhotoKit metadata call convoys behind it (live incident 2026-07-03: a
    /// scan hung >24 h with all 8 enrich workers — the entire Swift-concurrency
    /// cooperative pool — blocked behind one wedged call). NEVER call this from
    /// a concurrency task; go through `editedFallback`. The primary source for
    /// `edited` is the sidecar's `ZASSET.ZADJUSTMENTSSTATE` (semantically
    /// identical, zero XPC — see `QualitySidecar`).
    private static func editedViaPhotoKit(_ asset: PHAsset) -> Bool {
        if asset.adjustmentFormatIdentifier != nil { return true }
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .adjustmentData }
    }

    /// Wedge-proof wrapper around `editedViaPhotoKit`, for when the sidecar is
    /// unreadable (no Full Disk Access) — see `PhotoKitSyncLane` for the
    /// machinery. nil = could not determine (timed out, or the lane's breaker
    /// already tripped): callers keep their stored value (protection simply
    /// isn't upgraded — the safe direction for a best-effort signal).
    static func editedFallback(_ asset: PHAsset) async -> Bool? {
        await PhotoKitSyncLane.call { editedViaPhotoKit(asset) }
    }

    // MARK: - cheap, metadata-only (no pixels)

    /// True when the frame still carries original camera-capture metadata (EXIF
    /// Make/Model) rather than an EXIF-stripped social re-save.
    ///
    /// TODO(slice-1): reliable EXIF Make/Model is not cheaply available in the
    /// current Photo-building path. Reading it means
    /// `requestImageDataAndOrientation` (full image data → CGImageSource EXIF),
    /// which with `isNetworkAccessAllowed = false` returns nil for iCloud-evicted
    /// originals and is expensive per asset. Rather than ship a half-working
    /// heuristic that could mis-rank keepers, we leave this defaulting to `false`
    /// for now. Because it is purely a RANKING tiebreaker (never a delete
    /// trigger), a uniform `false` is safe: it just falls through to the existing
    /// format/size/earliest signals, exactly as before this slice. A pending
    /// Swift test (`original-camera ranking, pending real EXIF`) documents the
    /// intended behaviour for when this is wired.
    static func originalCamera(_ asset: PHAsset) -> Bool {
        false   // see TODO above — pending reliable on-device EXIF Make/Model
    }

    // MARK: - pixel-based, cluster-members only

    /// Document/scan/receipt/ID detection — conservative on purpose, with TWO
    /// corroborating signals required.
    ///
    /// Background: `VNDetectDocumentSegmentationRequest` returns a high-confidence
    /// near-full-frame rectangle for many NORMAL photos (a painting on a wall, a
    /// whiteboard in the background, a landscape framed by edges) — relying on it
    /// alone caused ordinary burst frames to be wrongly protected as "documents".
    ///
    /// Fix (FIX B): require BOTH:
    ///   1. A high-confidence document rectangle (≥0.9) from
    ///      `VNDetectDocumentSegmentationRequest`, AND
    ///   2. Substantial recognised text from `VNRecognizeTextRequest` — at least
    ///      `minTextObservations` distinct word-level observations, each with
    ///      confidence ≥ `minTextConfidence`.
    ///
    /// Rationale for thresholds:
    ///   • A genuine receipt/ID/scan has many text regions; ≥5 observations is a
    ///     conservative bar that a handwritten label on a box or a poster headline
    ///     won't clear but a receipt or form will.
    ///   • Per-observation confidence ≥ 0.5 filters OCR noise without being so
    ///     strict that difficult scan angles fail.
    ///   • Fast language correction is off (`usesLanguageCorrection = false`) to
    ///     avoid hallucinated words inflating the count.
    ///   • Network is disabled (`isNetworkAccessAllowed = false` on all requests) —
    ///     100 % on-device, consistent with the rest of the scan pipeline.
    ///
    /// FIX #4 — iCloud-eviction: when `cgImage()` returns nil (image not on-device
    /// / 2 s timeout) we cannot determine whether this frame is a document. Rather
    /// than silently returning `false` (which could let a real document slip into
    /// the auto-reject set), the primary entry point `isDocumentResult` returns
    /// `degraded = true` so the caller knows to withhold auto-seeding.
    ///
    /// Failure direction: unreadable image → `(false, degraded: true)`.
    ///                    ambiguous result / insufficient text → `(false, false)`.
    /// `localCG`: the 512px local thumbnail, if the caller already fetched it
    /// (enrichFlags shares one fetch with the sharpness pass — see `localThumb`).
    /// nil → fetch here, exactly as before.
    static func isDocumentResult(_ asset: PHAsset,
                                 manager: PHCachingImageManager,
                                 localCG: CGImage? = nil) async -> (isDocument: Bool, degraded: Bool) {
        // TWO-TIER fetch. Document detection dies on tiny thumbnails (measured
        // on a real handwritten-form scan: 256px → seg 0.46 and zero text —
        // no threshold survives that; 512px → seg 0.90 + text). But fetching
        // high-quality pixels for EVERY cluster member is a 20+ minute scan on
        // an optimize-storage library (live-measured). So:
        //   Tier 1: cheap opportunistic local thumbnail. If it's reasonably
        //           sized AND segmentation is clearly below suspicion, this is
        //           a confident NO at zero extra cost — the common case.
        //   Tier 2: only for suspicious-or-too-small tier-1 results, refetch at
        //           512px high quality (network allowed, timeout-guarded) and
        //           run the full two-path predicate on trustworthy pixels.
        let resolved: CGImage?
        if let localCG { resolved = localCG } else { resolved = await cgImage(asset, manager) }
        guard let localCG = resolved else {
            // Not even a local thumbnail → we genuinely do not know.
            return (false, true)
        }
        // Escalate on suspicion only. Even a tiny thumbnail of a real document
        // keeps some geometric signal (the live form case read 0.46 at 256px),
        // while ordinary photos sit well below the floor — gating escalation on
        // thumbnail SIZE instead re-fetched nearly the whole optimize-storage
        // library and blew the scan out to 15+ minutes (live-measured twice).
        let localSeg = await segConfidence(localCG)
        if localSeg < DocumentThresholds.suspicionFloor {
            // Confidently not a document at browse-time. KNOWN LIMIT: a real
            // document whose only local representation is a ~48px micro-thumb
            // can read seg=0.0 here and miss the badge (measured on a
            // handwritten-form scan). The deletion-suggestion path compensates
            // with `isDocumentHiQ` on trustworthy pixels before any pre-mark.
            return (false, false)
        }
        // 30s timeout: escalation usually means downloading the original from
        // iCloud (several MB) — the default 10s bound produced false "degraded"
        // results on real suspicious frames. Few frames reach this tier, so the
        // longer bound doesn't threaten overall scan time.
        guard let cg = await VisionGuards.cgImage(asset, manager,
                                                  target: CGSize(width: 512, height: 512),
                                                  mode: .aspectFit, resize: .fast,
                                                  timeoutNs: 30_000_000_000) else {
            // Escalation needed but image unavailable / timed out → unknown.
            return (false, true)
        }
        return (await documentVerdict(cg), false)
    }

    /// The full two-path document predicate over trustworthy pixels.
    ///
    /// Two corroboration paths (protective direction — a false positive only
    /// over-protects):
    ///  A. Moderate geometry + LOTS of text → printed receipt/scan/ID.
    ///  B. Strong geometry + ANY recognised text → handwritten forms, whose
    ///     words fast OCR mostly can't read (live-verified miss: a
    ///     handwritten-form scan pair got zero protection under the old
    ///     "0.9 AND ≥5 words" single path). A painting/landscape may clear
    ///     the geometry bar but has no text at all.
    private static func documentVerdict(_ cg: CGImage) async -> Bool {
        await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])

                // Pass 1: document segmentation.
                let docRequest = VNDetectDocumentSegmentationRequest()
                do {
                    try handler.perform([docRequest])
                } catch {
                    cont.resume(returning: false); return
                }
                let seg = docRequest.results?.first?.confidence ?? 0
                guard seg >= DocumentThresholds.segFloor else {
                    cont.resume(returning: false); return
                }

                // Pass 2: text recognition, only when geometry already passed.
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .fast   // fast: lower latency, still good for counting
                textRequest.usesLanguageCorrection = false   // no hallucinated words
                do {
                    try handler.perform([textRequest])
                } catch {
                    cont.resume(returning: false); return
                }
                let words = (textRequest.results ?? [])
                    .filter { $0.confidence >= DocumentThresholds.minTextConfidence }
                    .count

                cont.resume(returning:
                    (seg >= DocumentThresholds.segWithText
                        && words >= DocumentThresholds.minTextObservations)
                    || (seg >= DocumentThresholds.segStrong
                        && words >= DocumentThresholds.minTextObservationsStrong))
            }
        }
    }

    /// Document-detection thresholds, extracted so tuning is one edit (and the
    /// two corroboration paths are legible). Direction of safety: raising any
    /// bar risks missing a real document (protection hole); lowering only
    /// over-protects.
    enum DocumentThresholds {
        /// Tier-1 escalation bar: below this local-thumbnail segmentation the
        /// frame is treated as not-a-document without a high-quality refetch.
        /// Measured distribution (120K-library scan): 98% of cluster members
        /// read 0.0 and only ~145 read ≥0.1, so escalation stays cheap. Note a
        /// real document can still read 0.0 on a ~48px micro-thumb — that gap
        /// is closed by `isDocumentHiQ` on the deletion-suggestion path.
        static let suspicionFloor: Float = 0.1
        /// Below this segmentation confidence we don't even run OCR.
        static let segFloor: Float = 0.65
        /// Path A: moderate geometry, corroborated by substantial text.
        static let segWithText: Float = 0.65
        static let minTextObservations = 5
        /// Path B: strong geometry, corroborated by any confident text at all.
        static let segStrong: Float = 0.85
        static let minTextObservationsStrong = 1
        /// Per-observation recognition confidence floor.
        static let minTextConfidence: Float = 0.5
    }

    /// High-quality-only document check — skips the cheap tier entirely.
    /// Used as the LAST gate before a frame is auto-suggested for deletion:
    /// a 48px cached thumbnail carries zero signal for some real documents
    /// (measured seg=0.0 on a handwritten-form scan), so the suggestion path
    /// must judge on trustworthy pixels no matter what the browse-time badge
    /// said. Runs on a handful of frames (exact groups only) — cost is noise.
    static func isDocumentHiQ(_ asset: PHAsset, manager: PHCachingImageManager) async -> Bool? {
        guard let cg = await VisionGuards.cgImage(asset, manager,
                                                  target: CGSize(width: 512, height: 512),
                                                  mode: .aspectFit, resize: .fast,
                                                  timeoutNs: 30_000_000_000) else {
            return nil   // couldn't verify — caller must stay protective
        }
        return await documentVerdict(cg)
    }

    /// Segmentation confidence alone (tier-1 cheap screen), off the cooperative pool.
    private static func segConfidence(_ cg: CGImage) async -> Float {
        await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                let req = VNDetectDocumentSegmentationRequest()
                do { try handler.perform([req]) } catch { cont.resume(returning: 0); return }
                cont.resume(returning: req.results?.first?.confidence ?? 0)
            }
        }
    }

    /// Convenience bool-only wrapper (for callers that do not need the degraded flag).
    static func isDocument(_ asset: PHAsset, manager: PHCachingImageManager) async -> Bool {
        await isDocumentResult(asset, manager: manager).isDocument
    }

    /// On-device sharpness estimate (higher = sharper) via Laplacian variance over
    /// a small grayscale thumbnail — cheap and runs on the cached thumbnail. This
    /// is ONLY a within-group ranking tiebreaker; it is never a delete trigger, so
    /// an absolute calibration isn't needed — only the relative order within a
    /// cluster matters. Normalised to roughly 0…~1 by the `/ 1000` scale so it
    /// quantises into the same tenths buckets as quality in `rankKey`. Unreadable
    /// image → 0 (just doesn't win the sharpness tiebreak).
    static func sharpness(_ asset: PHAsset, manager: PHCachingImageManager) async -> Double {
        guard let gray = await grayBuffer(asset, manager, side: 64) else { return 0 }
        return laplacianVariance(gray.pixels, width: gray.width, height: gray.height)
    }

    /// Sharpness from an already-fetched thumbnail — lets a caller pay a single
    /// thumbnail fetch and feed it to both the document check and this pass
    /// (enrichFlags), instead of two identical 512px requests per member.
    static func sharpness(from cg: CGImage) -> Double {
        guard let gray = grayBuffer(from: cg, side: 64) else { return 0 }
        return laplacianVariance(gray.pixels, width: gray.width, height: gray.height)
    }

    /// The 512px local-only thumbnail both `isDocumentResult`'s tier-1 screen and
    /// `sharpness` consume. Exposed so a caller can fetch once and thread it into
    /// both, halving thumbnail I/O per cluster member.
    static func localThumb(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> CGImage? {
        await cgImage(asset, manager)
    }

    /// Variance of the 4-neighbour Laplacian over a grayscale buffer. High in a
    /// crisp image (sharp edges → large second derivative), low in a blurry one.
    private static func laplacianVariance(_ px: [Double], width w: Int, height h: Int) -> Double {
        guard w > 2, h > 2 else { return 0 }
        var lap: [Double] = []
        lap.reserveCapacity((w - 2) * (h - 2))
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = px[y * w + x]
                let v = px[(y - 1) * w + x] + px[(y + 1) * w + x]
                      + px[y * w + (x - 1)] + px[y * w + (x + 1)] - 4 * c
                lap.append(v)
            }
        }
        guard !lap.isEmpty else { return 0 }
        let mean = lap.reduce(0, +) / Double(lap.count)
        let variance = lap.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lap.count)
        // Scale so a sharp frame lands near ~1 and quantises into the tenths
        // buckets rankKey uses; exact calibration is irrelevant (ranking only).
        return variance / 1000.0
    }

    // MARK: - image helpers (on-device, never network)

    private static let visionQueue = DispatchQueue(label: "net.cver.snapsift.photoflags",
                                                   qos: .userInitiated, attributes: .concurrent)

    private static let imageTimeoutNs: UInt64 = 2_000_000_000

    /// One-shot continuation guarded by a timeout, mirroring LookAlikeScanner:
    /// a non-responding PhotoKit request (possible on an iCloud-optimised
    /// library) can never freeze the pass — after the deadline the frame is
    /// treated as unreadable.
    private final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<PlatformImage?, Never>?
        func set(_ c: CheckedContinuation<PlatformImage?, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ img: PlatformImage?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: img)
        }
    }

    /// 512px, NOT smaller: document detection dies on tiny thumbnails.
    /// Measured on a real handwritten-form scan — at 256px the segmentation
    /// confidence collapses to 0.46 with ZERO recognisable text (no threshold
    /// can save that); at 512px the same photo reads 0.90 + text. 512 is still
    /// cheap because this only ever runs on cluster members.
    private static func cgImage(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = false          // on-device only — never pull from iCloud
        opts.deliveryMode = .opportunistic           // whatever is cached locally now
        opts.resizeMode = .fast
        let box = ImageBox()
        let img: PlatformImage? = await withCheckedContinuation { cont in
            box.set(cont)
            manager.requestImage(for: asset, targetSize: CGSize(width: 512, height: 512),
                                 contentMode: .aspectFit, options: opts) { image, _ in
                box.finish(image)
            }
            Task { try? await Task.sleep(nanoseconds: imageTimeoutNs); box.finish(nil) }
        }
        guard let img else { return nil }
        return img.cgImageForProcessing
    }

    private static func grayBuffer(_ asset: PHAsset, _ manager: PHCachingImageManager,
                                   side: Int) async -> (pixels: [Double], width: Int, height: Int)? {
        guard let cg = await cgImage(asset, manager) else { return nil }
        return grayBuffer(from: cg, side: side)
    }

    private static func grayBuffer(from cg: CGImage,
                                   side: Int) -> (pixels: [Double], width: Int, height: Int)? {
        let w = side, h = side
        var data = [UInt8](repeating: 0, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data.map(Double.init), w, h)
    }
}
