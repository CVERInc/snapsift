import Foundation
import Photos
import Vision
import AppKit

/// Scores a frame by its faces using Vision, on-device. Within a burst the best
/// keeper is usually the frame where the most people are present with their eyes
/// open — exactly what a human would pick. Runs only on cluster members (a few
/// thousand images at most), never the whole library.
enum FaceScorer {

    /// Higher = a better "everyone looking good" frame. 0 when no faces / no image.
    static func score(asset: PHAsset, manager: PHCachingImageManager) async -> Double {
        guard let cg = await cgImage(for: asset, manager: manager) else { return 0 }
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return 0 }
        guard let faces = request.results, !faces.isEmpty else { return 0 }

        var total = 0.0
        for face in faces {
            // Each present face is worth a base point; open eyes add up to ~1 more,
            // and a confidently-detected, larger face counts a little extra.
            let openness = eyeOpenness(face)            // 0…~0.4
            let area = Double(face.boundingBox.width * face.boundingBox.height)
            total += 1.0 + openness * 2.5 + min(area, 0.25)
        }
        return (total * 1000).rounded() / 1000
    }

    /// Average eye-aspect-ratio across both eyes (height / width of the eye
    /// landmark region). Open ≈ 0.3+, closed ≈ 0.1.
    private static func eyeOpenness(_ face: VNFaceObservation) -> Double {
        guard let lm = face.landmarks else { return 0 }
        let eyes = [lm.leftEye, lm.rightEye].compactMap { $0 }
        guard !eyes.isEmpty else { return 0 }
        var sum = 0.0
        for eye in eyes {
            let pts = eye.normalizedPoints
            guard pts.count > 2 else { continue }
            let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
            let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
            if w > 0 { sum += h / w }
        }
        return sum / Double(eyes.count)
    }

    private static func cgImage(for asset: PHAsset, manager: PHCachingImageManager) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .exact
        let target = CGSize(width: 512, height: 512)   // enough to find small faces
        let nsImage: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
        guard let nsImage else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
