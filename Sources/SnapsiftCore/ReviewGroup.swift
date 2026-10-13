import Foundation

/// One reviewable near-duplicate cluster: the Core photos plus the currently
/// chosen keeper. Protected frames (favorite / edited / document — `Photo
/// .isProtected`) are never deletable by DEFAULT; the user can explicitly
/// force-reject them via the keyboard `⇧X` path or the mouse "include protected"
/// button, which both funnel through `setIncludeProtected` + a confirm dialog.
public struct ReviewGroup: Identifiable {
    public let id = UUID()
    public var photos: [Photo]
    public var keeperID: String
    /// Per-frame reject set: asset uuids the user wants deleted.
    /// SEEDED at scan time ONLY for verified exact-duplicate groups (see
    /// `seedExactRejections`); every other group seeds empty (keep all —
    /// the user decides). A frame is a deletion iff its uuid is in this set —
    /// `isDelete` and `deletionIDs` derive purely from here.
    public var rejected: Set<String> = []
    /// The subset of `rejected` that the app itself seeded (exact-duplicate
    /// suggestions). Everything else in `rejected` came from an explicit user
    /// action. Kept so the audit log can attribute each deletion honestly
    /// (`.exactDuplicate` vs `.userRejected`). Any bulk user override
    /// (keep-all / reject-all / re-seed) clears this — from that point on the
    /// group's rejections are the user's, not the app's.
    public var autoSeeded: Set<String> = []
    /// A confident, near-identical burst. Drives GROUPING/DISPLAY only (the
    /// "Near-identical" sidebar section): a confident group is near-identical
    /// but NOT proven interchangeable, so it never pre-seeds rejections.
    /// Deletion suggestions come exclusively from the exact-duplicate pass
    /// (`detectExactDuplicates` → `seedExactRejections`), which additionally
    /// byte-verifies the originals.
    ///
    /// FIX 4: default is FALSE — a group is uncertain until the scanner explicitly
    /// proves confidence (dHash spread ≤ threshold AND neural feature distance ≤
    /// threshold).
    public var confidentDupe = false

    // SLICE-1 INVARIANT (unchanged from prior model):
    //   • The scanner NEVER seeds a protected frame into `rejected`.
    //   • A protected frame can only enter `rejected` via explicit user action
    //     (keyboard ⇧X or mouse "include protected") — both require confirmation.
    //   • `includeProtected` = true is the signal that the user has confirmed
    //     the override for this group. It gates the commit dialog.
    /// Set to true only after explicit user confirmation. Required for the
    /// final commit-delete to include any protected frame in this group.
    public var includeProtected = false

    public init(photos: [Photo], keeperID: String) {
        self.photos = photos
        self.keeperID = keeperID
    }

    // MARK: - Derived state

    /// True when the user has explicitly cleared all rejections for this group.
    public var keepAll: Bool { rejected.isEmpty }
    /// True when every non-protected frame (that isn't the keeper) is rejected.
    public var deleteAll: Bool {
        // Same candidate set the `d` action seeds (Core `bulkRejectCandidates`):
        // keeper out, protected out, UNVERIFIABLE out. Asking whether frames the
        // bulk action is not allowed to mark are marked made `deleteAll` false
        // forever on any group holding an iCloud-evicted frame.
        let candidates = bulkRejectCandidates(photos: photos, keeperID: keeperID)
        guard !candidates.isEmpty else { return false }
        return candidates.isSubset(of: rejected)
    }

    /// The frame THAT WILL SURVIVE and that every surface names (Core
    /// `namedSurvivor`). A keeper that is marked but protected-and-not-
    /// overridden still survives, so it is still the keeper; and when the
    /// nominated keeper is itself marked while another frame survives, this
    /// names that other frame instead of answering "nobody". Three surfaces
    /// (gallery badge, sheet keeper row, no-survivor checkbox) used to give
    /// three different answers for exactly those states.
    public func isKeeper(_ p: Photo) -> Bool {
        namedSurvivor(photos: photos, keeperID: keeperID,
                      rejected: rejected, includeProtected: includeProtected)?.uuid == p.uuid
    }
    /// Would this frame actually be removed? Delegates to the Core rule so the
    /// protection guarantee has exactly one implementation — and one that the
    /// test suite executes directly (see SnapsiftCore/DeleteDecision.swift).
    public func isDelete(_ p: Photo) -> Bool {
        isEffectiveDeletion(p, rejected: rejected, includeProtected: includeProtected)
    }

    public var spanSec: Double { (photos.last?.takenAt ?? 0) - (photos.first?.takenAt ?? 0) }
    public var hasFavorite: Bool { photos.contains { $0.favorite } }
    public var hasVideo: Bool { photos.contains { $0.kind == 1 } }
    public var deletionIDs: [String] { photos.filter(isDelete).map(\.uuid) }
    /// Count of protected frames that are in `rejected` (regardless of includeProtected).
    public var protectedDeletionCount: Int { photos.filter { $0.isProtected && rejected.contains($0.uuid) }.count }
    /// Count of protected frames in this group (regardless of armed state).
    public var protectedCount: Int { photos.filter(\.isProtected).count }
    /// True when there are real frames that would be deleted.
    public var effectivelyArmed: Bool { !deletionIDs.isEmpty }
}
