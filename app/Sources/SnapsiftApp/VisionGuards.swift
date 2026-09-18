import Foundation
import Photos
@preconcurrency import Vision

/// Shared guards for the auxiliary Vision passes (FaceScorer, CategoryScanner),
/// mirroring the two hard-won safety rules already encoded in LookAlikeScanner:
///
///  1. Every PhotoKit image request gets a one-shot timeout — on an
///     iCloud-optimised library `requestImage` can simply never call back, and
///     a single stuck asset must never stall a whole pass.
///  2. Vision's `perform` is a synchronous, thread-blocking call — it must run
///     on a plain GCD queue, never on Swift's cooperative pool, or concurrent
///     callers wedge the pool and deadlock every awaited continuation.
enum VisionGuards {

    /// One-shot continuation box: image callback or timeout, first wins.
    private final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<PlatformImage?, Never>?
        func set(_ c: CheckedContinuation<PlatformImage?, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ img: PlatformImage?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: img)
        }
    }

    /// Off-pool queue for `VNImageRequestHandler.perform` (see rule 2).
    private static let visionQueue = DispatchQueue(label: "net.cver.snapsift.vision-aux",
                                                   qos: .userInitiated, attributes: .concurrent)

    /// Timeout-guarded thumbnail fetch. These passes may allow network (they
    /// want a decent-quality frame and run over cluster members only, not the
    /// whole library), so the bound is generous — but it is a bound.
    static func cgImage(_ asset: PHAsset, _ manager: PHCachingImageManager,
                        target: CGSize, mode: PHImageContentMode,
                        resize: PHImageRequestOptionsResizeMode,
                        timeoutNs: UInt64 = 10_000_000_000) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = resize
        let box = ImageBox()
        let img: PlatformImage? = await withCheckedContinuation { cont in
            box.set(cont)
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: mode, options: opts) { image, _ in
                box.finish(image)
            }
            Task { try? await Task.sleep(nanoseconds: timeoutNs); box.finish(nil) }
        }
        guard let img else { return nil }
        return img.cgImageForProcessing
    }

    /// Run Vision requests off the cooperative pool. Returns false on error.
    static func perform(_ requests: [VNRequest], on cg: CGImage) async -> Bool {
        await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform(requests); cont.resume(returning: true) }
                catch { cont.resume(returning: false) }
            }
        }
    }
}
