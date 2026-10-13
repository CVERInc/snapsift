import Foundation
import CoreGraphics
#if targetEnvironment(simulator)
import CoreML
#endif
@preconcurrency import Vision

/// Vision's `perform` is synchronous and thread-blocking. Run it on a plain
/// GCD queue, never Swift's cooperative pool: concurrent callers can wedge the
/// pool and deadlock every awaited image continuation and timeout.
public enum VisionGuards {

    /// Off-pool queue for `VNImageRequestHandler.perform` (see the pool-deadlock reason above).
    private static let visionQueue = DispatchQueue(label: "net.cver.snapsift.vision-aux",
                                                   qos: .userInitiated, attributes: .concurrent)

    /// The iOS Simulator cannot create Vision's accelerated inference context
    /// ("Failed to create espresso context"), so requests run on the CPU there.
    /// Devices and macOS keep Vision's default compute devices.
    public static func useSupportedComputeDevices(_ requests: [VNRequest]) {
        #if targetEnvironment(simulator)
        for request in requests {
            guard let stages = try? request.supportedComputeStageDevices else { continue }
            for (stage, devices) in stages {
                let cpu = devices.first { device in
                    if case .cpu = device { return true }
                    return false
                }
                if let cpu { request.setComputeDevice(cpu, for: stage) }
            }
        }
        #endif
    }

    /// Run Vision requests off the cooperative pool. Returns false on error.
    public static func perform(_ requests: [VNRequest], on cg: CGImage) async -> Bool {
        useSupportedComputeDevices(requests)
        return await withCheckedContinuation { cont in
            visionQueue.async {
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform(requests); cont.resume(returning: true) }
                catch { cont.resume(returning: false) }
            }
        }
    }
}
