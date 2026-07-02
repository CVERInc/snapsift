import Foundation

/// One asset in a candidate near-duplicate group. Mirrors the Python `Photo`
/// dataclass field-for-field so the two implementations stay interchangeable.
public struct Photo: Sendable, Equatable, Identifiable, Codable {
    public var id: String { uuid }

    public let uuid: String
    public let filename: String
    /// Capture time in seconds. The epoch is the PRODUCER'S: the Python CLI
    /// feeds Cocoa-epoch seconds straight from Photos.sqlite (add
    /// `appleEpochOffset` for Unix), while the app's `LibraryModel.makePhoto`
    /// feeds Unix seconds (`timeIntervalSince1970`). All Core math uses
    /// differences and ordering only, so both are fine — just never compare a
    /// CLI-produced `takenAt` with an app-produced one directly.
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

    // ── iCloud-eviction sentinel (FIX #4) ────────────────────────────────────
    // When the document/sharpness eval ran but the underlying image was
    // unavailable on-device (iCloud-evicted or timed out), we cannot determine
    // whether this frame is a document. We record that uncertainty here so the
    // caller can avoid auto-seeding such a frame into the rejected set — we must
    // stay in the safe keep-by-default direction.
    //
    // Sharpness-only degradation is NOT tracked here (sharpness is just a
    // tiebreaker; getting it wrong only reorders the keeper, never auto-deletes
    // a frame that might deserve protection). This flag means specifically:
    //   "document classification could NOT be performed — isDocument may be wrong".

    /// True when the pixel-based document eval (Vision) ran but the underlying
    /// image was not available on-device (iCloud-evicted / timeout), so
    /// `isDocument` may be incorrectly `false`. Such a frame must NOT be
    /// auto-seeded into the rejected set.
    public let documentEvalDegraded: Bool

    public init(uuid: String, filename: String, takenAt: Double,
                width: Int, height: Int, size: Int, uti: String,
                kind: Int = 0, favorite: Bool = false, quality: Double = 0,
                edited: Bool = false, isDocument: Bool = false,
                sharpness: Double = 0, originalCamera: Bool = false,
                documentEvalDegraded: Bool = false) {
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
        self.documentEvalDegraded = documentEvalDegraded
    }

    /// A frame a human likely wants to keep regardless of keeper choice: a
    /// favorite, an edited frame, or a document/scan. Such frames are NEVER in
    /// `deletions()`. This is the single protection predicate the whole app
    /// (Core + the SwiftUI `ReviewGroup`) routes through.
    public var isProtected: Bool { favorite || edited || isDocument }
}

/// Cocoa epoch → Unix epoch offset, in seconds.
public let appleEpochOffset: Double = 978_307_200
