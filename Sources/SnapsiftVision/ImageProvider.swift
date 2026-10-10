import CoreGraphics
import ImageIO

/// Each profile preserves one scan call site's pixel and latency requirements.
/// Source adapters own the fetch settings; analyzers only consume CGImages.
public enum ImageRequestProfile: Sendable, CaseIterable {
    case dHash
    case featurePrint
    case faceScoring
    case categoryLabels
    case documentLocal
    case documentHighQuality
}

/// Item identifiers are opaque to Vision. A missing image is unreadable, never
/// evidence that a frame is safe to remove. Membership lets batch passes skip
/// unknown identifiers just as the original asset lookup did.
public protocol ImageProvider {
    var itemIdentifiers: Set<String> { get }
    func image(for itemIdentifier: String, profile: ImageRequestProfile) async -> CGImage?
}
