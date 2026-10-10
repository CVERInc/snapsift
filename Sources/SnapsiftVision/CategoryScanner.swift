import Foundation
import CoreGraphics
import Vision

/// On-device semantic classification (Vision's VNClassifyImageRequest) used by
/// the "Similar sets" pass to bucket the whole library by what's in each photo —
/// cat, document, food, people… — across time, no uploads. Picks the most
/// specific reliable label, skipping over-generic ancestors like "animal".
public enum CategoryScanner {

    /// Over-generic taxonomy ancestors — we'd rather bucket by "cat" than "animal".
    private static let generic: Set<String> = [
        "animal", "mammal", "feline", "canine", "vertebrate", "organism",
        "material", "structure", "object", "equipment", "instrument", "artifact",
        "substance", "outdoor", "indoor", "color", "plant_organism", "people_group",
    ]

    /// The chosen bucket label for an asset, or nil if nothing is reliable.
    public static func category(for itemIdentifier: String, provider: any ImageProvider) async -> String? {
        await labels(for: itemIdentifier, provider: provider).first
    }

    /// Up to `limit` reliable, specific content labels for an asset (most
    /// specific first; over-generic ancestors dropped). Used to name a set.
    public static func labels(for itemIdentifier: String, provider: any ImageProvider, limit: Int = 3) async -> [String] {
        // Timeout-guarded + off-pool Vision via VisionGuards — one stuck
        // iCloud asset can't stall the similar-sets naming pass.
        guard let cg = await provider.image(for: itemIdentifier, profile: .categoryLabels)
        else { return [] }
        let request = VNClassifyImageRequest()
        guard await VisionGuards.perform([request], on: cg) else { return [] }
        let reliable = (request.results ?? [])
            .filter { $0.hasMinimumPrecision(0.3, forRecall: 0) && !generic.contains($0.identifier) }
        return Array(reliable.prefix(limit).map(\.identifier))
    }

    /// A label like "interior_room" → "Interior room" for display.
    public static func displayName(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ").capitalized
    }

}
