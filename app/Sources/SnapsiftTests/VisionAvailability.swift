import Foundation
import CoreGraphics
@preconcurrency import Vision

/// Whether this machine can run Vision inference at all. GitHub's macOS VM
/// runners cannot ("Could not create inference context", on every compute
/// device including the CPU), so feature prints never exist there and the
/// pipeline correctly refuses to certify duplicates. Checks that need a real
/// feature print go through `checkNeedsVision` and are reported as skipped,
/// never silently passed.
let visionInferenceAvailable: Bool = {
    let size = 64
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
    guard let cg = ctx.makeImage() else { return false }
    let request = VNGenerateImageFeaturePrintRequest()
    do {
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return request.results?.first is VNFeaturePrintObservation
    } catch {
        return false
    }
}()

var skipped = 0
func checkNeedsVision(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard visionInferenceAvailable else {
        print("  – skipped (no Vision inference on this machine): \(label)")
        skipped += 1
        return
    }
    check(condition(), label)
}
