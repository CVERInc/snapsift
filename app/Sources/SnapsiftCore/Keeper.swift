import Foundation

/// UTI keep-priority — higher wins. Mirrors Python `pick.UTI_PRIORITY`.
///
/// RAW formats rank at 90 — above JPEG (80) but below HEIC (100).
/// Rationale: a RAW file is the highest-fidelity capture available; it is never
/// a re-compressed derivative. HEIC beats RAW only because HEIC is the iPhone
/// native format and represents the processed result with Apple's ISP tuning
/// (which is typically preferred for viewing). If the user shot RAW+JPEG the
/// RAW is the keeper. DNG uses `com.adobe.raw-image` (the canonical UTI Apple
/// registers for DNG in the system UTI database).
public let utiPriority: [String: Int] = [
    "public.heic": 100,
    "public.heif": 100,
    // RAW formats — above JPEG, below HEIC
    "com.adobe.raw-image": 90,          // DNG (Adobe / Apple canonical)
    "public.camera-raw-image": 90,      // generic RAW abstract base type
    "com.canon.cr2-raw-image": 90,      // Canon CR2
    "com.canon.cr3-raw-image": 90,      // Canon CR3
    "com.nikon.raw-image": 90,          // Nikon NEF
    "com.nikon.nrw-raw-image": 90,      // Nikon NRW (compact Nikon RAW)
    "com.sony.arw-raw-image": 90,       // Sony ARW
    "com.fuji.raf-raw-image": 90,       // Fujifilm RAF
    "com.panasonic.rw2-raw-image": 90,  // Panasonic RW2
    "com.dng": 90,                       // alternative DNG UTI seen on some imports
    "public.jpeg": 80,
    "public.png": 60,
    "public.tiff": 50,
    "com.compuserve.gif": 20,
    "public.mpeg-4": 70,
    "com.apple.quicktime-movie": 70,
]

/// Quantise a quality score to integer tenths with deterministic, platform-
/// independent round-half-up — `floor(q*10 + 0.5)`. This is the SAME rule the
/// Python CLI uses (`pick.quality_bucket`), NOT Swift's default round-half-away
/// `.rounded()`, so the app and the CLI always agree on the keeper. Quantising
/// means noise-level quality differences fall through to format/size.
public func qualityBucket(_ quality: Double) -> Int { Int((quality * 10 + 0.5).rounded(.down)) }

/// Sort key for "most worth keeping" — higher is better. Mirrors Python
/// `pick.rank` exactly (the CLI and the app MUST pick the same keeper).
///
/// Priority, highest first:
///   1. favorite           — the user starred it; always wins.
///   2. quality (bucketed) — Apple's own aesthetic score, quantised to tenths so
///                           noise-level differences fall through to the signals
///                           below rather than splitting hairs.
///   3. originalCamera     — a genuine camera capture (intact EXIF Make/Model)
///                           beats an EXIF-stripped social-app re-save. Sits
///                           ABOVE sharpness/format/size on purpose: "newer or
///                           larger" must NOT beat "the real original", and a
///                           re-compressed re-save is rarely the better keeper.
///   4. sharpness (bucketed) — within an otherwise-tied group, prefer the
///                           crisper frame. Quantised to tenths like quality so
///                           sensor noise can't dominate, and slotted BELOW
///                           quality so it can never override the real quality
///                           signal. This is the ONLY thing sharpness does: it
///                           reorders the keeper within a real multi-frame group.
///                           It is NEVER a standalone delete trigger (see
///                           `deletions`, which keys off `isProtected`, not blur).
///   5. UTI priority       — original-format files (HEIC > JPG > …).
///   6. file size          — bigger same-format file = less compression.
///   7. earliest take      — the original capture if all else is equal.
///
/// A named `Comparable` struct (not a tuple — Swift tuples only compare up to six
/// elements) so the seven-way priority above is lexicographic and explicit.
public struct RankKey: Comparable {
    public let favorite: Int
    public let quality: Int
    public let originalCamera: Int
    public let sharpness: Int
    public let uti: Int
    public let size: Int
    public let negTakenAt: Double
    /// Final deterministic tie-break: when every real signal (including
    /// takenAt) ties, keeper identity must not depend on input order — the
    /// same library must always pick the same keeper across scans.
    public let uuid: String

    public static func < (a: RankKey, b: RankKey) -> Bool {
        if a.favorite != b.favorite { return a.favorite < b.favorite }
        if a.quality != b.quality { return a.quality < b.quality }
        if a.originalCamera != b.originalCamera { return a.originalCamera < b.originalCamera }
        if a.sharpness != b.sharpness { return a.sharpness < b.sharpness }
        if a.uti != b.uti { return a.uti < b.uti }
        if a.size != b.size { return a.size < b.size }
        if a.negTakenAt != b.negTakenAt { return a.negTakenAt < b.negTakenAt }
        return a.uuid < b.uuid
    }
}

public func rankKey(_ p: Photo) -> RankKey {
    RankKey(favorite: p.favorite ? 1 : 0,
            quality: qualityBucket(p.quality),
            originalCamera: p.originalCamera ? 1 : 0,
            sharpness: qualityBucket(p.sharpness),
            uti: utiPriority[p.uti] ?? 0,
            size: p.size,
            negTakenAt: -p.takenAt,
            uuid: p.uuid)
}

/// The single frame to keep from a cluster. Precondition: the cluster is
/// non-empty (clustering never emits empty groups); an empty input traps here
/// rather than returning a fabricated keeper.
public func keeper(_ group: [Photo]) -> Photo {
    group.max { rankKey($0) < rankKey($1) }!
}

/// Photos to delete from a cluster: everything that is neither the keeper nor a
/// PROTECTED frame. A frame is protected if it is a favorite, an edited frame,
/// or a document/scan (`Photo.isProtected`) — such frames are sacred and NEVER
/// deleted, so a cluster of all-protected frames deletes nothing. This single
/// predicate is the whole app's protection guard; the App layer's `ReviewGroup`
/// routes through `isProtected` too so a protected frame can never end up
/// pre-marked anywhere. Ranking signals (sharpness, originalCamera) only choose
/// WHICH frame is the keeper — they can never put a frame into this set.
///
/// Degenerate inputs degrade to "delete nothing" — the only safe answer for the
/// function whose output feeds the delete pipeline: an empty group has nothing
/// to delete (and must not crash picking a keeper from nobody), and a
/// single-frame group keeps its one frame.
public func deletions(_ group: [Photo]) -> [Photo] {
    guard let keep = group.max(by: { rankKey($0) < rankKey($1) }) else { return [] }
    return group.filter { $0.uuid != keep.uuid && !$0.isProtected }
}

// MARK: - Keeper "Why" transparency

/// The dominant reason a frame was chosen as the keeper.
/// Ordered from highest to lowest priority, matching `RankKey`.
public enum KeeperReason: String, Sendable, Equatable {
    case favorite        // user starred it — always wins
    case quality         // highest Apple quality bucket
    case originalCamera  // intact EXIF Make/Model — not a re-save
    case sharpness       // sharpest within an otherwise-tied group
    case format          // best format (HEIC > JPEG > …)
    case size            // largest file (less compression)
    case earliest        // earliest capture — the original take
}

/// Derive the dominant reason a keeper was chosen from the signals in `RankKey`.
/// Returns the highest-priority signal where the keeper strictly beats at least one
/// other frame in the group — so the label always reflects a real decision.
///
/// If the group has only one member (degenerate), defaults to `.earliest`.
public func keeperReason(photos: [Photo], keeperID: String) -> KeeperReason {
    guard let keeper = photos.first(where: { $0.uuid == keeperID }) else { return .earliest }
    let others = photos.filter { $0.uuid != keeperID }
    guard !others.isEmpty else { return .earliest }

    // Check priority from highest to lowest — first signal where keeper wins vs any other.
    // Favorite only counts as the reason when it actually broke a tie: in an
    // all-favorite group the star decided nothing, so fall through.
    if keeper.favorite && others.contains(where: { !$0.favorite }) { return .favorite }

    let kQ = qualityBucket(keeper.quality)
    if others.contains(where: { qualityBucket($0.quality) < kQ }) { return .quality }

    if keeper.originalCamera && others.contains(where: { !$0.originalCamera }) { return .originalCamera }

    let kS = qualityBucket(keeper.sharpness)
    if others.contains(where: { qualityBucket($0.sharpness) < kS }) { return .sharpness }

    let kU = utiPriority[keeper.uti] ?? 0
    if others.contains(where: { (utiPriority[$0.uti] ?? 0) < kU }) { return .format }

    if others.contains(where: { $0.size < keeper.size }) { return .size }

    return .earliest
}

// MARK: - No-survivor guard

/// Count the number of review groups that would be completely emptied —
/// every frame marked for deletion, leaving zero survivors — after applying
/// the given per-group rejected sets.
///
/// A group has no survivor when ALL its photos are in `rejected` AND
/// `includeProtected` is true for that group (otherwise protected frames survive).
///
/// This is a pure, testable helper that takes the minimum inputs required
/// by the UI guard so it doesn't need to import the App layer.
///
/// Parameters match the App layer's `ReviewGroup`:
///   - `groups`: sequence of (photos, rejected, includeProtected) tuples
public func noSurvivorGroupCount(
    _ groups: [(photos: [Photo], rejected: Set<String>, includeProtected: Bool)]
) -> Int {
    groups.filter { g in
        // A frame "survives" if it is NOT effectively deleted.
        let survivors = g.photos.filter { p in
            guard g.rejected.contains(p.uuid) else { return true }  // not rejected → survives
            if p.isProtected && !g.includeProtected { return true }  // protected & not overridden → survives
            return false  // would be deleted
        }
        return survivors.isEmpty
    }.count
}

/// The carry-forward state of a reviewed cluster after some of its frames were
/// deleted. `nil` `photos` means the cluster is resolved (fewer than two frames
/// remain) and should be dropped entirely.
///
/// Re-grouping after a delete pass MUST preserve the user's per-group review
/// decisions. Dropping them silently flips a "keep all" group back into one that
/// pre-marks its non-keepers for deletion — the exact opposite of what the user
/// asked, and a trust/accuracy red line (it would silently re-mark protected
/// photos). This pure helper keeps `keepAll` / `deleteAll` / `confidentDupe`
/// intact and only re-derives the keeper when the previous one was deleted.
public func regroupAfterDeletion(photos: [Photo],
                                 keeperID: String,
                                 removed: Set<String>) -> (photos: [Photo], keeperID: String)? {
    let remaining = photos.filter { !removed.contains($0.uuid) }
    guard remaining.count >= 2 else { return nil }
    let newKeeperID = remaining.contains { $0.uuid == keeperID } ? keeperID
        : keeper(remaining).uuid
    return (remaining, newKeeperID)
}
