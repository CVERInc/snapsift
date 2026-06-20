import Foundation
import Photos
import Vision
import AppKit
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

    // MARK: - cheap, metadata-only (no pixels)

    /// True when the user applied adjustments to this asset.
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
    static func edited(_ asset: PHAsset) -> Bool {
        if asset.adjustmentFormatIdentifier != nil { return true }
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .adjustmentData }
    }

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
    static func isDocumentResult(_ asset: PHAsset,
                                 manager: PHCachingImageManager) async -> (isDocument: Bool, degraded: Bool) {
        guard let cg = await cgImage(asset, manager) else {
            // Image not on-device / timed out → we genuinely do not know.
            return (false, true)
        }

        // Minimum number of distinct word-level text observations required.
        // A receipt / scan / ID card comfortably exceeds 5; a photo of a person
        // in front of a building sign does not.
        let minTextObservations = 5
        // Per-observation recognition confidence floor.
        let minTextConfidence: Float = 0.5

        let docResult: Bool = await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])

                // Pass 1: document segmentation.
                let docRequest = VNDetectDocumentSegmentationRequest()
                do {
                    try handler.perform([docRequest])
                } catch {
                    cont.resume(returning: false); return
                }
                guard (docRequest.results?.first?.confidence ?? 0) >= 0.9 else {
                    cont.resume(returning: false); return
                }

                // Pass 2: text recognition on the same cached CGImage.
                // Only run this (cheaper but still non-trivial) pass when the
                // document rectangle already passed — avoids running OCR on every
                // cluster member.
                let textRequest = VNRecognizeTextRequest()
                textRequest.recognitionLevel = .fast   // fast: lower latency, still good for counting
                textRequest.usesLanguageCorrection = false   // no hallucinated words
                do {
                    try handler.perform([textRequest])
                } catch {
                    cont.resume(returning: false); return
                }
                let observations = textRequest.results ?? []
                let highConfidenceWords = observations.filter { $0.confidence >= minTextConfidence }
                // Require at least `minTextObservations` confident text regions.
                // A photo of a person / scene may have 0–2; a scan has many more.
                cont.resume(returning: highConfidenceWords.count >= minTextObservations)
            }
        }
        return (docResult, false)
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
        private var cont: CheckedContinuation<NSImage?, Never>?
        func set(_ c: CheckedContinuation<NSImage?, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ img: NSImage?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: img)
        }
    }

    private static func cgImage(_ asset: PHAsset, _ manager: PHCachingImageManager) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = false          // on-device only — never pull from iCloud
        opts.deliveryMode = .opportunistic           // whatever is cached locally now
        opts.resizeMode = .fast
        let box = ImageBox()
        let img: NSImage? = await withCheckedContinuation { cont in
            box.set(cont)
            manager.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256),
                                 contentMode: .aspectFit, options: opts) { image, _ in
                box.finish(image)
            }
            Task { try? await Task.sleep(nanoseconds: imageTimeoutNs); box.finish(nil) }
        }
        guard let img else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func grayBuffer(_ asset: PHAsset, _ manager: PHCachingImageManager,
                                   side: Int) async -> (pixels: [Double], width: Int, height: Int)? {
        guard let cg = await cgImage(asset, manager) else { return nil }
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
