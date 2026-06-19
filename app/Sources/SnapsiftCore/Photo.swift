import Foundation

/// One asset in a candidate near-duplicate group. Mirrors the Python `Photo`
/// dataclass field-for-field so the two implementations stay interchangeable.
public struct Photo: Sendable, Equatable, Identifiable {
    public var id: String { uuid }

    public let uuid: String
    public let filename: String
    /// Cocoa-epoch seconds (2001-01-01 UTC). Add `appleEpochOffset` for Unix.
    public let takenAt: Double
    public let width: Int
    public let height: Int
    public let size: Int        // original file size, bytes
    public let uti: String      // uniform type identifier
    public let kind: Int        // 0 = image, 1 = video
    public let favorite: Bool
    public let quality: Double  // composite of Apple's aesthetic scores

    // ── protection-class flags (slice 1) ─────────────────────────────────────
    // A photo is NEVER deletable if it is favorite OR edited OR a document. The
    // Core only RESPECTS these flags; detecting them (PhotoKit adjustments,
    // Vision document segmentation) is the App layer's job. False positives just
    // over-protect, which is the safe direction — the #1 rule is to never mark a
    // frame a human likely wants to keep.

    /// The user applied edits/adjustments (e.g. a PhotoKit `.adjustmentData`
    /// resource). Edited frames are sacred — never deleted.
    public let edited: Bool
    /// A document / ID / receipt / scan — a utility photo people keep on purpose.
    /// Never deleted.
    public let isDocument: Bool

    // ── within-group ranking signals (slice 1) — NEVER delete triggers ───────

    /// On-device sharpness estimate (higher = sharper). Used ONLY to prefer the
    /// crisper frame as keeper *within* an interchangeable group. It can never on
    /// its own add a photo to `deletions()`, and we deliberately do NOT try to
    /// tell artistic blur from low-light blur — that's a confident-wrong trap.
    public let sharpness: Double
    /// True when the frame still carries original camera-capture metadata
    /// (EXIF Make/Model/lens) rather than being an EXIF-stripped social-app
    /// re-save. Prefers the genuine original over a re-compressed copy; newer or
    /// larger does NOT mean better. A ranking signal only, below the protection
    /// guarantees.
    public let originalCamera: Bool

    public init(uuid: String, filename: String, takenAt: Double,
                width: Int, height: Int, size: Int, uti: String,
                kind: Int = 0, favorite: Bool = false, quality: Double = 0,
                edited: Bool = false, isDocument: Bool = false,
                sharpness: Double = 0, originalCamera: Bool = false) {
        self.uuid = uuid
        self.filename = filename
        self.takenAt = takenAt
        self.width = width
        self.height = height
        self.size = size
        self.uti = uti
        self.kind = kind
        self.favorite = favorite
        self.quality = quality
        self.edited = edited
        self.isDocument = isDocument
        self.sharpness = sharpness
        self.originalCamera = originalCamera
    }

    /// A frame a human likely wants to keep regardless of keeper choice: a
    /// favorite, an edited frame, or a document/scan. Such frames are NEVER in
    /// `deletions()`. This is the single protection predicate the whole app
    /// (Core + the SwiftUI `ReviewGroup`) routes through.
    public var isProtected: Bool { favorite || edited || isDocument }
}

/// Cocoa epoch → Unix epoch offset, in seconds.
public let appleEpochOffset: Double = 978_307_200
