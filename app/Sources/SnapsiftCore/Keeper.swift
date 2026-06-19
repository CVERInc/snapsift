import Foundation

/// UTI keep-priority — higher wins. Mirrors Python `pick.UTI_PRIORITY`.
public let utiPriority: [String: Int] = [
    "public.heic": 100,
    "public.heif": 100,
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

    public static func < (a: RankKey, b: RankKey) -> Bool {
        if a.favorite != b.favorite { return a.favorite < b.favorite }
        if a.quality != b.quality { return a.quality < b.quality }
        if a.originalCamera != b.originalCamera { return a.originalCamera < b.originalCamera }
        if a.sharpness != b.sharpness { return a.sharpness < b.sharpness }
        if a.uti != b.uti { return a.uti < b.uti }
        if a.size != b.size { return a.size < b.size }
        return a.negTakenAt < b.negTakenAt
    }
}

public func rankKey(_ p: Photo) -> RankKey {
    RankKey(favorite: p.favorite ? 1 : 0,
            quality: qualityBucket(p.quality),
            originalCamera: p.originalCamera ? 1 : 0,
            sharpness: qualityBucket(p.sharpness),
            uti: utiPriority[p.uti] ?? 0,
            size: p.size,
            negTakenAt: -p.takenAt)
}

/// The single frame to keep from a cluster.
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
public func deletions(_ group: [Photo]) -> [Photo] {
    let keep = keeper(group)
    return group.filter { $0.uuid != keep.uuid && !$0.isProtected }
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
