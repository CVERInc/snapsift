import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The delete pipeline's decision logic, as pure functions.
//
// WHY THIS FILE EXISTS: every guard below used to live inside `LibraryModel`
// (an @MainActor ObservableObject in the SnapsiftApp executable target, which
// no test target can import). The test suite therefore re-implemented each rule
// as a "mirror" function inside the test file — so deleting the REAL guard kept
// every test green. Two independent red-team reviews landed on the same finding.
//
// The rules now live here, in SnapsiftCore, which `SnapsiftTests` imports and
// `LibraryModel` CALLS. A test that fails when the rule is removed is only
// possible if the test and the app execute the same code — that is the whole
// point of this file. Nothing here touches PhotoKit, SwiftUI or the file
// system: the App layer gathers the live facts, this layer decides.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Effective deletion / survivors (ONE definition)

/// Would this frame actually be removed, given its group's review state?
///
/// The order of the three clauses is the protection guarantee:
///   1. not marked            → survives;
///   2. UNVERIFIABLE          → survives, unconditionally. `includeProtected`
///      cannot override it: informed consent needs a fact to consent to, and
///      "we could not read whether you edited this" is not one;
///   3. protected (favorite / edited / document) → survives unless the user
///      took the explicit ⇧X + confirm path for this group.
public func isEffectiveDeletion(_ p: Photo,
                                rejected: Set<String>,
                                includeProtected: Bool) -> Bool {
    guard rejected.contains(p.uuid) else { return false }
    if p.isUnverifiable { return false }
    if p.isProtected && !includeProtected { return false }
    return true
}

/// The frames of a group that would remain in the library after a commit.
public func survivors(photos: [Photo],
                      rejected: Set<String>,
                      includeProtected: Bool) -> [Photo] {
    photos.filter { !isEffectiveDeletion($0, rejected: rejected, includeProtected: includeProtected) }
}

/// The keeper AS THE CONFIRMATION SURFACE MUST SHOW IT: the nominated keeper,
/// but only when it actually survives this commit. `nil` means "no survivor" —
/// either the keeper is itself being removed or the whole group is.
///
/// The pre-commit sheet and the no-survivor counter both call this, so the
/// sheet can no longer print "⚠️ no photo left" for a group the model counts as
/// having a survivor (or vice versa).
public func survivingKeeper(photos: [Photo],
                            keeperID: String,
                            rejected: Set<String>,
                            includeProtected: Bool) -> Photo? {
    guard let k = photos.first(where: { $0.uuid == keeperID }) else { return nil }
    return isEffectiveDeletion(k, rejected: rejected, includeProtected: includeProtected) ? nil : k
}

/// True when a commit would empty this group completely.
public func hasNoSurvivor(photos: [Photo],
                          rejected: Set<String>,
                          includeProtected: Bool) -> Bool {
    survivors(photos: photos, rejected: rejected, includeProtected: includeProtected).isEmpty
}

// MARK: - Delete-set composition (bulk actions + auto-seed)

/// The frames a BULK action (`d` reject-all, keep-all's re-seed, the
/// exact-duplicate auto-seed) is allowed to put into the rejected set:
/// everything that is neither the keeper nor protected nor unverifiable.
///
/// `isDeletable` is the single predicate — an earlier version of `rejectAll`
/// filtered on `!isProtected` alone, so pressing `d` on a group containing
/// iCloud-evicted frames (document eval never ran) marked them for deletion
/// while the label promised "protected photos stay safe".
public func bulkRejectCandidates(photos: [Photo], keeperID: String) -> Set<String> {
    Set(photos.filter { $0.uuid != keeperID && $0.isDeletable }.map(\.uuid))
}

/// Frames a bulk action had to LEAVE OUT because they are unverifiable, so the
/// UI can say "N frames couldn't be classified and were not marked" instead of
/// quietly marking fewer photos than the button promised.
public func bulkRejectWithheld(photos: [Photo], keeperID: String) -> Set<String> {
    Set(photos.filter { $0.uuid != keeperID && $0.isUnverifiable && !$0.isProtected }.map(\.uuid))
}

// MARK: - Commit-time sweep

/// One group as it enters the final commit.
public struct CommitGroupState {
    public let index: Int
    public let photos: [Photo]
    public let keeperID: String
    public let rejected: Set<String>
    public let includeProtected: Bool

    public init(index: Int, photos: [Photo], keeperID: String,
                rejected: Set<String>, includeProtected: Bool) {
        self.index = index
        self.photos = photos
        self.keeperID = keeperID
        self.rejected = rejected
        self.includeProtected = includeProtected
    }
}

/// What a LIVE re-check found, moments before `performChanges`.
public struct LiveCommitFacts {
    /// Every asset id that resolved in the live fetch — deletion candidates AND
    /// each group's keeper. An id missing here no longer exists in the library.
    public let resolved: Set<String>
    /// uuid → live favorite flag (a free prefetched PHAsset property).
    public let favoriteNow: [String: Bool]
    /// uuid → live edited flag, for the frames the re-check could DETERMINE.
    /// A MISSING key means undetermined — the protective direction.
    public let editedNow: [String: Bool]

    public init(resolved: Set<String>,
                favoriteNow: [String: Bool] = [:],
                editedNow: [String: Bool] = [:]) {
        self.resolved = resolved
        self.favoriteNow = favoriteNow
        self.editedNow = editedNow
    }
}

/// A frame the sweep pulled out of the commit, and why.
public struct SweptFrame: Equatable {
    public enum Reason: String, Equatable {
        /// Favorited or edited since the scan — a real, newly-known protection.
        case newlyProtected
        /// Edit state unreadable right now — unknown ⇒ protected.
        case undetermined
        /// The asset no longer exists (deleted outside snapsift since the scan).
        case vanished
    }
    public let uuid: String
    public let groupIndex: Int
    public let reason: Reason
    /// Live flags, meaningful for `.newlyProtected`.
    public let favorite: Bool
    public let edited: Bool
}

/// The verdict of the commit-time sweep.
public struct CommitDecision: Equatable {
    /// The ids that may go to `PHAssetChangeRequest.deleteAssets`.
    public let deleteIDs: [String]
    /// Groups pulled out WHOLE because the photo they promised to keep is gone.
    public let withdrawnGroupIndexes: [Int]
    /// Frames removed from the commit, with the reason for each.
    public let swept: [SweptFrame]

    public var newlyProtectedCount: Int { swept.filter { $0.reason == .newlyProtected }.count }
    public var undeterminedCount: Int { swept.filter { $0.reason == .undetermined }.count }
    public var vanishedCount: Int { swept.filter { $0.reason == .vanished }.count }
}

/// THE last gate before `performChanges`.
///
/// Doctrine 3 says the commit re-checks protection against the LIVE library.
/// Three things are re-checked here, and each failure mode has its own exit:
///
///  • **The keeper must still exist.** The scan-to-commit window is hours long
///    on a big library; "two identical shots, I deleted one on my phone" is the
///    most natural action a user can take in it, and the one they take on the
///    frame snapsift picked as keeper. Committing anyway leaves ZERO copies of
///    that image while the sheet said "KEEP IMG_1234" and the audit log names a
///    photo that no longer exists. So: a group whose surviving keeper does not
///    resolve is WITHDRAWN WHOLE — none of its frames are deleted, and the
///    caller tells the user which and why. (A group the user deliberately
///    emptied — no survivor, acknowledged via the sheet checkbox — has no
///    keeper to lose and is left alone.)
///
///  • **Favorite / edited since the scan** → the frame is newly protected. It is
///    un-marked, not merely skipped: this is new, durable knowledge.
///
///  • **Edit state undetermined** (no Full Disk Access, or the library the
///    sidecar reads could not be confirmed, and the per-asset PhotoKit fallback
///    also failed) → cannot verify, cannot delete. The frame is UN-MARKED and
///    the caller flags it `editedUndetermined` so the UI shows it as degraded.
///    Holding the mark while silently skipping the frame — the behaviour this
///    replaces — leaves the user looking at a mark that no commit will ever
///    honour and no surface explains.
public func commitSweepDecision(groups: [CommitGroupState],
                                live: LiveCommitFacts) -> CommitDecision {
    var deleteIDs: [String] = []
    var withdrawn: [Int] = []
    var swept: [SweptFrame] = []

    for g in groups {
        let candidates = g.photos.filter {
            isEffectiveDeletion($0, rejected: g.rejected, includeProtected: g.includeProtected)
        }
        guard !candidates.isEmpty else { continue }

        // Keeper liveness. Only meaningful when this group HAS a surviving
        // keeper; a deliberately emptied group has none by construction.
        if let keeper = survivingKeeper(photos: g.photos, keeperID: g.keeperID,
                                        rejected: g.rejected,
                                        includeProtected: g.includeProtected),
           !live.resolved.contains(keeper.uuid) {
            withdrawn.append(g.index)
            continue
        }

        for p in candidates {
            guard live.resolved.contains(p.uuid) else {
                swept.append(SweptFrame(uuid: p.uuid, groupIndex: g.index,
                                        reason: .vanished, favorite: false, edited: false))
                continue
            }
            // Frames already protected at scan time were shown as protected in
            // the sheet and force-included there; they are not re-swept.
            if p.isProtected {
                deleteIDs.append(p.uuid)
                continue
            }
            let fav = live.favoriteNow[p.uuid] ?? p.favorite
            if let editedLive = live.editedNow[p.uuid] {
                if fav || editedLive {
                    swept.append(SweptFrame(uuid: p.uuid, groupIndex: g.index,
                                            reason: .newlyProtected,
                                            favorite: fav, edited: editedLive))
                } else {
                    deleteIDs.append(p.uuid)
                }
            } else if fav {
                swept.append(SweptFrame(uuid: p.uuid, groupIndex: g.index,
                                        reason: .newlyProtected,
                                        favorite: true, edited: false))
            } else {
                swept.append(SweptFrame(uuid: p.uuid, groupIndex: g.index,
                                        reason: .undetermined, favorite: false, edited: false))
            }
        }
    }
    return CommitDecision(deleteIDs: deleteIDs,
                          withdrawnGroupIndexes: withdrawn,
                          swept: swept)
}

// MARK: - "Carries unique metadata" (exact-duplicate protection class)

/// The library-level, non-pixel content a copy can carry. `nil` means NOT
/// DETERMINED — the probe could not read that signal — which is deliberately
/// distinct from `0` / `false`.
public struct LibraryMetadata: Equatable {
    /// How many user albums the asset belongs to.
    public let albumCount: Int?
    /// Whether the asset carries a user-entered caption / title / description.
    public let hasDescription: Bool?

    public init(albumCount: Int? = nil, hasDescription: Bool? = nil) {
        self.albumCount = albumCount
        self.hasDescription = hasDescription
    }

    public var isFullyDetermined: Bool { albumCount != nil && hasDescription != nil }
}

/// Two byte-identical files are interchangeable AS PIXELS. They are not
/// interchangeable as LIBRARY ENTRIES: one of them may be the copy the user
/// wrote a caption on and filed into three albums. Deleting that copy loses
/// work the keeper does not carry, and the two thumbnails in the sheet are
/// indistinguishable, so the user cannot catch it.
///
/// True when the candidate carries something the keeper lacks. Anything the
/// probe could not determine counts as "carries" — unknown ⇒ protected.
public func carriesUniqueMetadata(candidate: LibraryMetadata,
                                  keeper: LibraryMetadata) -> Bool {
    guard let cAlbums = candidate.albumCount, let kAlbums = keeper.albumCount,
          let cDesc = candidate.hasDescription, let kDesc = keeper.hasDescription
    else { return true }   // undetermined ⇒ treat as carrying
    if cAlbums > kAlbums { return true }
    if cDesc && !kDesc { return true }
    return false
}

// MARK: - Library identity (is the sidecar the library PhotoKit serves?)

public enum LibraryIdentity: Equatable {
    case verified
    case unverified(UnverifiedReason)

    public var isVerified: Bool { self == .verified }
}

public enum UnverifiedReason: String, Equatable {
    /// We could not learn where the Photos library actually is.
    case pathUnknown
    /// The sidecar we read is NOT the library Photos is using (a copy left in
    /// ~/Pictures after the real library moved to an external disk keeps the
    /// same asset UUIDs, so every id still "matches" — only the path differs).
    case pathMismatch
    /// Right path, frozen contents: assets PhotoKit can see are absent from the
    /// database, so it is a snapshot, not the live file.
    case staleContents
}

/// Decide whether the sidecar database may be trusted for PROTECTION facts.
///
/// `sampledNewest` / `foundInSidecar`: the N most recently created assets as
/// PhotoKit reports them, and how many of those the sidecar knows. A database
/// at the right path but frozen (an old copy, a restored snapshot) fails here.
///
/// Anything short of a positive answer is a MISMATCH, never a shrug: `edited`
/// then comes from the per-asset PhotoKit fallback, and where that fails too
/// the frame is undetermined ⇒ protected, with a banner saying so.
public func evaluateLibraryIdentity(sidecarPath: String?,
                                    photosLibraryPath: String?,
                                    sampledNewest: Int = 0,
                                    foundInSidecar: Int = 0) -> LibraryIdentity {
    guard let sidecarPath, !sidecarPath.isEmpty else { return .unverified(.pathUnknown) }
    guard let photosLibraryPath, !photosLibraryPath.isEmpty else { return .unverified(.pathUnknown) }
    func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
    guard normalize(sidecarPath) == normalize(photosLibraryPath) else {
        return .unverified(.pathMismatch)
    }
    if sampledNewest > 0 && foundInSidecar < sampledNewest { return .unverified(.staleContents) }
    return .verified
}

// MARK: - Own-write token restamp

/// After one of snapsift's own library writes we move the staleness anchor
/// forward, so a relaunch doesn't treat our own album write as an external
/// mutation and drop every byte-verified pre-mark. That is only honest if OUR
/// write was the only thing that happened: a big album write runs for tens of
/// seconds on a large library, and an edit synced from an iPhone during that
/// window would be stamped over — the restore's whole reason to re-check.
///
/// True only when every persistent change since the pre-write token is
/// attributable to the ids we just touched. An INSERT is never ours (we never
/// create assets), so any insert means "something else moved".
public func ownWriteOnly(inserted: Set<String>,
                         updated: Set<String>,
                         deleted: Set<String>,
                         ourIDs: Set<String>) -> Bool {
    inserted.isEmpty
        && updated.subtracting(ourIDs).isEmpty
        && deleted.subtracting(ourIDs).isEmpty
}

// MARK: - Preferred language

/// Pick the app language from the user's ORDERED language preferences.
///
/// `Locale.current` on macOS follows the FORMAT REGION, not the language: a
/// Japanese-speaking user with region United States got an English app, and a
/// Taiwanese user working in Japan got a Japanese one. `Locale.preferredLanguages`
/// is the actual "Preferred Languages" list from System Settings, in order.
/// Returns the first tag the app supports, or nil (caller defaults to English).
public func preferredLanguageTag(from preferred: [String],
                                 supported: (String) -> Bool) -> String? {
    preferred.first(where: supported)
}
