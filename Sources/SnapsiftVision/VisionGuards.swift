import Foundation
import CoreGraphics
@preconcurrency import Vision

/// Vision's `perform` is synchronous and thread-blocking. Run it on a plain
/// GCD queue, never Swift's cooperative pool: concurrent callers can wedge the
/// pool and deadlock every awaited image continuation and timeout.
public enum VisionGuards {

    /// Off-pool queue for `VNImageRequestHandler.perform` (see the pool-deadlock reason above).
    private static let visionQueue = DispatchQueue(label: "net.cver.snapsift.vision-aux",
                                                   qos: .userInitiated, attributes: .concurrent)

    /// Run Vision requests off the cooperative pool. Returns false on error.
    public static func perform(_ requests: [VNRequest], on cg: CGImage) async -> Bool {
        await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform(requests); cont.resume(returning: true) }
                catch { cont.resume(returning: false) }
            }
        }
    }
}
