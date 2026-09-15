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

    /// True when the frame's EDIT state could not be determined at all: the
    /// quality sidecar is absent or belongs to a library we could not confirm is
    /// the one PhotoKit serves, AND the per-asset PhotoKit fallback also failed
    /// (breaker tripped / timed out). `edited` is then a guess, not a fact, so
    /// the frame must be treated exactly like a protected one — unknown ⇒
    /// protected. Distinct from `edited == true`, which is a KNOWN protection
    /// the user can still override via the informed-consent path; an
    /// undetermined frame has nothing to consent to, so it is never deletable.
    public let editedUndetermined: Bool

    public init(uuid: String, filename: String, takenAt: Double,
                width: Int, height: Int, size: Int, uti: String,
                kind: Int = 0, favorite: Bool = false, quality: Double = 0,
                edited: Bool = false, isDocument: Bool = false,
                sharpness: Double = 0, originalCamera: Bool = false,
                documentEvalDegraded: Bool = false,
                editedUndetermined: Bool = false) {
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
        self.editedUndetermined = editedUndetermined
    }

    // MARK: - Backward-compatible decoding
    //
    // `last-scan.json` is the SOLE store of the user's review decisions, so a
    // snapshot written by an older build (no `editedUndetermined` key, and for
    // very old files none of the slice-1 flags) must still decode. A synthesized
    // Decodable would fail the whole file and the restore would surface as
    // "unreadable" — i.e. every mark silently gone. Missing flags decode to
    // `false`, which is what those builds meant by omitting them.

    enum CodingKeys: String, CodingKey {
        case uuid, filename, takenAt, width, height, size, uti, kind, favorite
        case quality, edited, isDocument, sharpness, originalCamera
        case documentEvalDegraded, editedUndetermined
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        filename = try c.decode(String.self, forKey: .filename)
        takenAt = try c.decode(Double.self, forKey: .takenAt)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        size = try c.decode(Int.self, forKey: .size)
        uti = try c.decode(String.self, forKey: .uti)
        kind = try c.decodeIfPresent(Int.self, forKey: .kind) ?? 0
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        isDocument = try c.decodeIfPresent(Bool.self, forKey: .isDocument) ?? false
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        originalCamera = try c.decodeIfPresent(Bool.self, forKey: .originalCamera) ?? false
        documentEvalDegraded = try c.decodeIfPresent(Bool.self, forKey: .documentEvalDegraded) ?? false
        editedUndetermined = try c.decodeIfPresent(Bool.self, forKey: .editedUndetermined) ?? false
    }

    /// A frame a human likely wants to keep regardless of keeper choice: a
    /// favorite, an edited frame, or a document/scan. Such frames are NEVER in
    /// `deletions()`. This is the single protection predicate the whole app
    /// (Core + the SwiftUI `ReviewGroup`) routes through.
    public var isProtected: Bool { favorite || edited || isDocument }

    /// True when a protection INPUT could not be determined: the edit state is
    /// unreadable (`editedUndetermined`) or the document eval ran blind
    /// (`documentEvalDegraded`, iCloud-evicted / timed out). Doctrine: unknown ⇒
    /// protected. Such a frame is never auto-seeded, never enters a delete set,
    /// and — unlike a KNOWN protection — cannot be force-included, because there
    /// is no fact for the user to consent to overriding.
    public var isUnverifiable: Bool { editedUndetermined || documentEvalDegraded }

    /// The single positive predicate the whole delete pipeline routes through:
    /// a frame may be deleted only when it is neither protected nor
    /// unverifiable. `deletions()`, the App's bulk-reject seeding and the
    /// commit-time sweep all key off this, so adding a new protection input
    /// means adding it here once, not in five call sites.
    public var isDeletable: Bool { !isProtected && !isUnverifiable }

    /// A copy with one or more protection / eval flags overridden, every other
    /// field preserved. Used when a flag is RE-EVALUATED after the scan: a
    /// rotation save makes a frame `edited`, a live commit-time re-check upgrades
    /// `favorite`/`edited`, an exact-pass hi-q pass confirms `isDocument`. Keeps
    /// those in-place rebuilds honest and free of field-drift.
    public func with(favorite: Bool? = nil, edited: Bool? = nil,
                     isDocument: Bool? = nil, documentEvalDegraded: Bool? = nil,
                     editedUndetermined: Bool? = nil) -> Photo {
        Photo(uuid: uuid, filename: filename, takenAt: takenAt,
              width: width, height: height, size: size, uti: uti, kind: kind,
              favorite: favorite ?? self.favorite, quality: quality,
              edited: edited ?? self.edited, isDocument: isDocument ?? self.isDocument,
              sharpness: sharpness, originalCamera: originalCamera,
              documentEvalDegraded: documentEvalDegraded ?? self.documentEvalDegraded,
              editedUndetermined: editedUndetermined ?? self.editedUndetermined)
    }
}

/// Cocoa epoch → Unix epoch offset, in seconds.
public let appleEpochOffset: Double = 978_307_200
