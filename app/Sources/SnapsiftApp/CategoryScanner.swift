import Foundation
import Photos
import Vision
import AppKit

/// On-device semantic classification (Vision's VNClassifyImageRequest) used by
/// the "Similar sets" pass to bucket the whole library by what's in each photo —
/// cat, document, food, people… — across time, no uploads. Picks the most
/// specific reliable label, skipping over-generic ancestors like "animal".
enum CategoryScanner {

    /// Over-generic taxonomy ancestors — we'd rather bucket by "cat" than "animal".
    private static let generic: Set<String> = [
        "animal", "mammal", "feline", "canine", "vertebrate", "organism",
        "material", "structure", "object", "equipment", "instrument", "artifact",
        "substance", "outdoor", "indoor", "color", "plant_organism", "people_group",
    ]

    /// The chosen bucket label for an asset, or nil if nothing is reliable.
    static func category(for asset: PHAsset, manager: PHCachingImageManager) async -> String? {
        await labels(for: asset, manager: manager).first
    }

    /// Up to `limit` reliable, specific content labels for an asset (most
    /// specific first; over-generic ancestors dropped). Used to name a set.
    static func labels(for asset: PHAsset, manager: PHCachingImageManager, limit: Int = 3) async -> [String] {
        guard let cg = await cgImage(for: asset, manager: manager) else { return [] }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let reliable = (request.results ?? [])
            .filter { $0.hasMinimumPrecision(0.3, forRecall: 0) && !generic.contains($0.identifier) }
        return Array(reliable.prefix(limit).map(\.identifier))
    }

    /// A label like "interior_room" → "Interior room" for display.
    static func displayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func cgImage(for asset: PHAsset, manager: PHCachingImageManager) async -> CGImage? {
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        let nsImage: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256),
                                 contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
        guard let nsImage else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
