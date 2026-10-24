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

/// THE frame the confirmation surface must name as the one that stays — and
/// the single source every surface reads, so they cannot describe two
/// different realities for the same group.
///
/// `survivingKeeper` answers a narrower question ("does the NOMINATED keeper
/// survive?") and returns nil in a state the app can reach: mark the keeper
/// with `X` when nothing outranks it, then un-mark a different frame. The
/// keeper stays nominated-and-marked while that other frame is what actually
/// stays. The sheet then printed "⚠️ no photo left" (nil keeper) while the
/// no-survivor checkbox stayed hidden (`hasNoSurvivor` == false) and the
/// commit quietly kept a third thing — three surfaces, three stories.
///
/// Definition: the nominated keeper when it survives, otherwise the
/// best-ranked frame that does survive, and nil ONLY when the group really
/// would be emptied. By construction `namedSurvivor(...) == nil` is exactly
/// `hasNoSurvivor(...)`, which is the invariant the tests pin.
public func namedSurvivor(photos: [Photo],
                          keeperID: String,
                          rejected: Set<String>,
                          includeProtected: Bool) -> Photo? {
    if let k = survivingKeeper(photos: photos, keeperID: keeperID,
                               rejected: rejected, includeProtected: includeProtected) {
        return k
    }
    return survivors(photos: photos, rejected: rejected, includeProtected: includeProtected)
        .max { rankKey($0) < rankKey($1) }
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
///
/// DISPLAY-ONLY, not a pending queue: this is not "withheld, but could still
/// be marked" — an unverifiable frame can NEVER be marked (`isEffectiveDeletion`
/// refuses it unconditionally, `includeProtected` included). The count exists
/// so the UI can name what happened; the frames it counts are the ones the App
/// layer collects into the "Needs a look" Photos album (see `AlbumWriter`) for
/// the human to decide there, per the 2026-09-16 ruling: unclassifiable ⇒
/// never a delete candidate, always surfaced.
public func bulkRejectWithheld(photos: [Photo], keeperID: String) -> Set<String> {
    Set(photos.filter { $0.uuid != keeperID && $0.isUnverifiable && !$0.isProtected }.map(\.uuid))
}

// MARK: - Nomination verbs (K and ⇧K), as state transitions

/// The two fields a nomination verb may move: who this group keeps, and which
/// frames are marked. Everything else about a group (`autoSeeded`,
/// `includeProtected`) is App-layer bookkeeping and stays there.
public struct GroupMarkState: Equatable {
    public let keeperID: String
    public let rejected: Set<String>
    public init(keeperID: String, rejected: Set<String>) {
        self.keeperID = keeperID
        self.rejected = rejected
    }
}

/// `K` / `1–9` — nominate `frameID` as keeper. The SAFE direction, by
/// construction: it only ever REMOVES from `rejected`, never inserts, so no
/// nomination keystroke can widen a deletion. `LibraryModel.promote` calls this
/// and then does its own `autoSeeded` / `includeProtected` bookkeeping.
public func promoteState(_ state: GroupMarkState, to frameID: String) -> GroupMarkState {
    GroupMarkState(keeperID: frameID, rejected: state.rejected.subtracting([frameID]))
}

/// `⇧K` — "keep only this one": nominate `keeperID` AND mark every other frame
/// in the group that may be marked.
///
/// K : ⇧K :: X : ⇧X — plain verb, stronger verb. The stronger one here is
/// still only a MARKING action: nothing leaves the library until the pre-commit
/// sheet is confirmed. ⇧K again on the same frame, with nothing touched in
/// between, puts the group back exactly as it was (`keepOnlyUndoTarget`); `A`
/// keeps everything. Plain `K` is NOT an undo — it un-marks one frame.
///
/// What it marks is `bulkRejectCandidates` — THE one composition rule, shared
/// with `d` (reject-all) and the exact-duplicate auto-seed. That is the whole
/// reason this function exists rather than a second filter written at the call
/// site: "deletable" is defined once (`Photo.isDeletable`), so ⇧K itself never
/// ADDS a mark to a protected (favorite / edited / document) or UNVERIFIABLE
/// frame. Only the per-frame ⇧X informed-consent path can force a KNOWN
/// protection.
///
/// …and it never REMOVES one the owner made himself either (ruling 2026-09-18).
/// "They stay as they are" cuts both ways: a favorite the owner deliberately
/// force-marked with ⇧X, having read the confirmation, is a decision this verb
/// has no business quietly undoing — and an undo that shows up as FEWER marks is
/// still an undo the owner did not ask for. So the result CARRIES those marks
/// over: `bulkRejectCandidates` ∪ (already-rejected protected frames), minus the
/// new keeper. `promote`'s own removal is what un-marks the nominated frame, so
/// ⇧K on a force-marked favorite still keeps it, as the verb promises.
///
/// The carry-over set is `isProtected` only, NOT `isDeletable`'s other half: an
/// unverifiable frame cannot legitimately be in `rejected` to begin with
/// (`toggleReject` refuses to insert one, `forceReject` guards against it, and
/// `isEffectiveDeletion` would refuse it unconditionally), so carrying one would
/// preserve a mark that can never fire and no surface explains. Where it somehow
/// exists, ⇧K drops it — the honest direction.
///
/// `includeProtected` is untouched here by design: ⇧K adds nothing that needs
/// consent, and the flag is group-level state the App layer owns
/// (`LibraryModel.keepOnly` applies `promote`'s existing rule, which can only
/// turn the override OFF, and only when no protected frame is marked any more).
///
/// Idempotent: feeding its own output back in yields the same state. On an
/// exact-duplicate group that already carries pre-seeded marks it lands on
/// keeper-plus-rest with the focused frame as keeper.
public func keepOnlyState(photos: [Photo],
                          keeperID: String,
                          rejected: Set<String>) -> GroupMarkState {
    let ownProtectedMarks = Set(photos.filter { $0.isProtected && rejected.contains($0.uuid) }
                                      .map(\.uuid))
    let marks = bulkRejectCandidates(photos: photos, keeperID: keeperID)
        .union(ownProtectedMarks)
        .subtracting([keeperID])
    return GroupMarkState(keeperID: keeperID, rejected: marks)
}

// MARK: - Verb guards and the ⇧K undo

/// Is `frameID` one of this group's frames? The guard every verb that takes a
/// frame id must pass before it writes that id into group state.
///
/// `keepOnly` always had it; `promote` did not, so a stale focus (same group
/// id, different members) could write a FOREIGN uuid into `keeperID`: no frame
/// wears the keep badge, and the next `D` silently falls back to `photos[0]` —
/// the app's pick replacing the owner's (check 2026-10-11, safety-r4 P2-1).
public func isGroupMember(_ frameID: String, of photos: [Photo]) -> Bool {
    photos.contains { $0.uuid == frameID }
}

/// Everything ⇧K can move in a group, so its undo can put ALL of it back.
public struct GroupMarkSnapshot: Equatable {
    public let keeperID: String
    public let rejected: Set<String>
    public let autoSeeded: Set<String>
    public let includeProtected: Bool
    public init(keeperID: String, rejected: Set<String>,
                autoSeeded: Set<String>, includeProtected: Bool) {
        self.keeperID = keeperID
        self.rejected = rejected
        self.autoSeeded = autoSeeded
        self.includeProtected = includeProtected
    }
}

/// What one ⇧K did to one group: the state it found and the state it left.
/// Held in memory only, per group; never persisted.
public struct KeepOnlyUndo: Equatable {
    public let before: GroupMarkSnapshot
    public let after: GroupMarkSnapshot
    public init(before: GroupMarkSnapshot, after: GroupMarkSnapshot) {
        self.before = before
        self.after = after
    }
}

/// ⇧K pressed again on the frame it just kept, with NOTHING changed since:
/// the state to put back, or nil when this press is not an undo.
///
/// An EXACT undo or none at all. It returns `undo.before` verbatim — the marks,
/// keeper and override the owner had one keystroke ago — and only when
///   • the group is still precisely what that ⇧K left (`current == undo.after`:
///     any X / K / A / D / commit sweep in between and this is a fresh ⇧K),
///   • the press is on the same frame (⇧K on a different frame is a new
///     nomination, not a retraction), and
///   • every id it would restore still names a frame of the group.
/// It never composes a set: there is no path here that marks a frame the owner
/// had not already marked himself immediately before ⇧K.
public func keepOnlyUndoTarget(current: GroupMarkSnapshot,
                               undo: KeepOnlyUndo?,
                               frameID: String,
                               photos: [Photo]) -> GroupMarkSnapshot? {
    guard let undo, current == undo.after, frameID == undo.after.keeperID else { return nil }
    let ids = Set(photos.map(\.uuid))
    guard ids.contains(undo.before.keeperID),
          undo.before.rejected.isSubset(of: ids) else { return nil }
    return undo.before
}

/// Is any protected frame of this group marked? `includeProtected` (the ⇧X
/// consent) must not outlive the last one — the ONE rule every verb below
/// applies. It can only turn the override OFF.
private func hasProtectedMark(_ photos: [Photo], _ rejected: Set<String>) -> Bool {
    photos.contains { $0.isProtected && rejected.contains($0.uuid) }
}

/// `K` / `1–9` as a complete action: the state to write, or nil = do nothing.
///
/// This is what `PhotoLibrarySession.promote` applies, whole — the membership
/// guard, `promoteState`, the provenance of the nominated frame, and the
/// override rule are one decision here, so the session cannot nominate without
/// passing the guard and the suite runs the code the app runs. (Folder Mode's
/// `FolderReviewState.apply(.promote)` carries the same guard of its own.)
public func nominateAction(photos: [Photo],
                           current: GroupMarkSnapshot,
                           to frameID: String) -> GroupMarkSnapshot? {
    guard isGroupMember(frameID, of: photos) else { return nil }
    let next = promoteState(GroupMarkState(keeperID: current.keeperID, rejected: current.rejected),
                            to: frameID)
    return GroupMarkSnapshot(keeperID: next.keeperID,
                             rejected: next.rejected,
                             autoSeeded: current.autoSeeded.subtracting([frameID]),
                             includeProtected: current.includeProtected
                                && hasProtectedMark(photos, next.rejected))
}

/// What one ⇧K press does.
public enum KeepOnlyOutcome: Equatable {
    /// This press was the undo: write this state and forget the undo record.
    case undone(GroupMarkSnapshot)
    /// A fresh ⇧K: write this state; `remember` is the undo record to keep,
    /// or nil when the press changed nothing (there is nothing to go back to,
    /// and a second press must not announce a restore that did not happen).
    case applied(GroupMarkSnapshot, remember: KeepOnlyUndo?)
}

/// `⇧K` as a complete action (nil = the frame is not in this group). Shared by
/// the Photos session and Folder Mode's review state.
///
/// PROVENANCE: a mark the exact-duplicate pass seeded and ⇧K left standing
/// stays `autoSeeded`; marks ⇧K adds are the user's. It only ever shrinks
/// `autoSeeded`.
public func keepOnlyAction(photos: [Photo],
                           current: GroupMarkSnapshot,
                           undo: KeepOnlyUndo?,
                           frameID: String) -> KeepOnlyOutcome? {
    guard isGroupMember(frameID, of: photos) else { return nil }
    if let back = keepOnlyUndoTarget(current: current, undo: undo,
                                     frameID: frameID, photos: photos) {
        return .undone(back)
    }
    let next = keepOnlyState(photos: photos, keeperID: frameID, rejected: current.rejected)
    let after = GroupMarkSnapshot(keeperID: next.keeperID,
                                  rejected: next.rejected,
                                  autoSeeded: current.autoSeeded.intersection(next.rejected),
                                  includeProtected: current.includeProtected
                                    && hasProtectedMark(photos, next.rejected))
    return .applied(after, remember: after == current ? nil
                                                      : KeepOnlyUndo(before: current, after: after))
}

/// `D` as a complete action: the state to write and how many frames it had to
/// leave out because they are unverifiable. nil for an empty group.
///
/// The keeper is not changed; a `keeperID` that names no frame falls back to
/// the first frame for the purpose of "who is spared", as it always did.
public func rejectAllAction(photos: [Photo],
                            current: GroupMarkSnapshot) -> (state: GroupMarkSnapshot, withheld: Int)? {
    guard let first = photos.first else { return nil }
    let spared = isGroupMember(current.keeperID, of: photos) ? current.keeperID : first.uuid
    let marks = bulkRejectCandidates(photos: photos, keeperID: spared)
    return (GroupMarkSnapshot(keeperID: current.keeperID,
                              rejected: marks,
                              autoSeeded: [],   // user overrode — the marks are theirs now
                              includeProtected: current.includeProtected
                                && hasProtectedMark(photos, marks)),
            bulkRejectWithheld(photos: photos, keeperID: spared).count)
}

/// May this key press reach the single-letter verbs (X K A D R 1–9 ⌫ …)?
///
/// Only a press carrying none of ⌘ ⌃ ⌥. SPEC §2: ⌘⏎ is the only key that
/// changes data and ⌘⌫ opens the sheet — but those are menu Commands, and when
/// a menu item is DISABLED its key equivalent is not consumed, so ⌘⌫ with
/// nothing marked fell through to the plain ⌫ verb and crossed out the focused
/// photo; ⌘A / ⌘D / ⌘K / ⌘1 landed on keep-all / reject-all / nominate the
/// same way (check 2026-10-11, a11y-keys §3). Folder Mode's handler refused ⌘
/// and ⌃ but let ⌥ through. Shift is NOT in this list: ⇧X, ⇧K and ⇧R are
/// verbs in their own right.
public func isPlainVerbKey(command: Bool, control: Bool, option: Bool) -> Bool {
    !command && !control && !option
}

/// A key press that MAY act as a verb. It can only be constructed from a press
/// that passes `isPlainVerbKey`, and the handlers' verb helpers take this type
/// rather than raw modifiers — so in the Photos grid, the preview and Folder
/// Mode there is no way to reach K / X / ⌫ / R without the gate having been
/// asked.
public struct VerbKeyPress: Equatable {
    public let shift: Bool
    public let isRepeat: Bool

    public init?(command: Bool, control: Bool, option: Bool, shift: Bool, isRepeat: Bool) {
        guard isPlainVerbKey(command: command, control: control, option: option) else { return nil }
        self.shift = shift
        self.isRepeat = isRepeat
    }

    public enum KeepVerb: Equatable { case nominate, keepOnly, swallow }

    /// Which K this is. ⇧K toggles (press again = undo), so a HELD ⇧K must not
    /// flip the group back and forth at the key-repeat rate: auto-repeat of ⇧K
    /// is swallowed. Plain K is idempotent and repeats harmlessly.
    public var keepVerb: KeepVerb {
        guard shift else { return .nominate }
        return isRepeat ? .swallow : .keepOnly
    }
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

/// Why a whole group was pulled out of the commit. Both answers mean the same
/// thing to the library — nothing in that group is deleted — but they are
/// different news to the user, so they are different strings.
public enum GroupWithdrawal: String, Equatable {
    /// The photo the sheet named as the one to KEEP no longer resolves.
    case keeperMissing
    /// Every frame this group would have left behind is gone from the library.
    /// Committing would leave ZERO copies of the image.
    case noSurvivorLeft
}

/// One group pulled out of the commit, and why.
public struct WithdrawnGroup: Equatable {
    public let index: Int
    public let reason: GroupWithdrawal
    public init(index: Int, reason: GroupWithdrawal) {
        self.index = index
        self.reason = reason
    }
}

/// The verdict of the commit-time sweep.
public struct CommitDecision: Equatable {
    /// The ids that may go to `PHAssetChangeRequest.deleteAssets`.
    public let deleteIDs: [String]
    /// Groups pulled out WHOLE, with the reason for each.
    public let withdrawnGroups: [WithdrawnGroup]
    /// Groups pulled out WHOLE — indexes only, for callers that just count.
    public var withdrawnGroupIndexes: [Int] { withdrawnGroups.map(\.index) }
    /// Frames removed from the commit, with the reason for each.
    public let swept: [SweptFrame]

    public var keeperMissingCount: Int {
        withdrawnGroups.filter { $0.reason == .keeperMissing }.count
    }
    public var noSurvivorLeftCount: Int {
        withdrawnGroups.filter { $0.reason == .noSurvivorLeft }.count
    }

    public var newlyProtectedCount: Int { swept.filter { $0.reason == .newlyProtected }.count }
    public var undeterminedCount: Int { swept.filter { $0.reason == .undetermined }.count }
    public var vanishedCount: Int { swept.filter { $0.reason == .vanished }.count }
}

/// THE last gate before `performChanges`.
///
/// Doctrine 3 says the commit re-checks protection against the LIVE library.
/// Three things are re-checked here, and each failure mode has its own exit:
///
///  • **Something must still be left.** The scan-to-commit window is hours long
///    on a big library; "two identical shots, I deleted one on my phone" is the
///    most natural action a user can take in it, and the one they take on the
///    frame snapsift picked as keeper. Committing anyway leaves ZERO copies of
///    that image while the sheet said "KEEP IMG_1234" and the audit log names a
///    photo that no longer exists.
///
///    The gate is therefore asked about the SURVIVORS, not about the nominated
///    keeper alone: at least one frame this group intends to leave behind must
///    resolve in the live fetch. Guarding only the nominee was a hole with a
///    reachable path into it — mark the keeper with `X`, then un-mark another
///    frame: the nominee stays nominated-and-marked, the OTHER frame is what
///    survives, `survivingKeeper` is nil, and the old code read that nil as
///    "the user deliberately emptied this group" and waved the whole commit
///    through. If that one real survivor had meanwhile been deleted on a
///    phone, every copy of the image went to Recently Deleted.
///
///    A group that really is deliberately empty (no survivors at all,
///    acknowledged via the sheet checkbox) has nothing to lose and is left
///    alone. A group whose NOMINATED keeper is gone is still withdrawn even
///    when another frame survives: the sheet promised that photo by name.
///    Both exits report their own reason — see `GroupWithdrawal`.
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
    var withdrawn: [WithdrawnGroup] = []
    var swept: [SweptFrame] = []

    for g in groups {
        let candidates = g.photos.filter {
            isEffectiveDeletion($0, rejected: g.rejected, includeProtected: g.includeProtected)
        }
        guard !candidates.isEmpty else { continue }

        // Survival gate — ONE function, shared with the pre-sheet check.
        if let reason = groupWithdrawalReason(photos: g.photos, keeperID: g.keeperID,
                                              rejected: g.rejected,
                                              includeProtected: g.includeProtected,
                                              resolved: live.resolved) {
            withdrawn.append(WithdrawnGroup(index: g.index, reason: reason))
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
                          withdrawnGroups: withdrawn,
                          swept: swept)
}

/// Would this group be pulled out of the commit whole, and why? `nil` = it may
/// proceed.
///
/// THE zero-survivor guard, in one place so the pre-sheet check
/// (`LibraryModel.withdrawnGroupIDs`) and the commit-time gate
/// (`commitSweepDecision`) can never drift apart — and so the fetch that feeds
/// `resolved` has one obvious obligation: it must cover EVERY survivor, not
/// just the nominated keeper. An id that was never fetched is missing from
/// `resolved`, which now reads as "gone" — fail-safe, but only because the
/// caller is told so here.
///
/// Order matters: a missing nominee is reported as `.keeperMissing` even when
/// it is also the last survivor, because "the photo we promised to keep is
/// gone" is the more specific, more useful sentence.
public func groupWithdrawalReason(photos: [Photo],
                                  keeperID: String,
                                  rejected: Set<String>,
                                  includeProtected: Bool,
                                  resolved: Set<String>) -> GroupWithdrawal? {
    if let keeper = survivingKeeper(photos: photos, keeperID: keeperID,
                                    rejected: rejected, includeProtected: includeProtected),
       !resolved.contains(keeper.uuid) {
        return .keeperMissing
    }
    let remaining = survivors(photos: photos, rejected: rejected,
                              includeProtected: includeProtected)
    // A group with no survivors AT ALL is the deliberate "delete everything
    // here" case: the user acknowledged it on the sheet and there is nothing
    // left to lose. A group that DOES intend to leave something behind must
    // still have one of those frames in the library.
    if !remaining.isEmpty && !remaining.contains(where: { resolved.contains($0.uuid) }) {
        return .noSurvivorLeft
    }
    return nil
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

/// True exactly when what was READ shows the candidate carries something the
/// keeper lacks: more albums (both counts read), or a caption the keeper does
/// not carry. Unread signals never make a copy "known" — those copies are
/// still withheld by `carriesUniqueMetadata`, but reported as undetermined.
///
/// A keeper whose description reads `nil` counts as lacking the caption: on
/// iOS a keeper with no caption reads nil (its title cannot be read) yet
/// certainly lacks the caption, so a captioned copy counts as known.
public func knownToCarryUniqueMetadata(candidate: LibraryMetadata,
                                       keeper: LibraryMetadata) -> Bool {
    if let cAlbums = candidate.albumCount, let kAlbums = keeper.albumCount,
       cAlbums > kAlbums { return true }
    if candidate.hasDescription == true && keeper.hasDescription != true { return true }
    return false
}

// MARK: - Snapsift's own organizational albums (never count as "user data")

/// Count only the ALBUMS THE USER actually filed this photo into — excluding
/// any of snapsift's own organizational albums (bursts / blurry / documents /
/// exact-duplicates / needs-a-look, in every language, current or legacy).
///
/// `carriesUniqueMetadata` treats album membership as evidence a copy is worth
/// keeping. Without this exclusion, snapsift's OWN "Sort into Albums" pass
/// would poison that signal: whichever byte-identical copy a PREVIOUS run
/// happened to file into "Snapsift · Burst Candidates" (or, after the album
/// this ships, "Snapsift · Needs a look") would outrank its literal duplicate
/// on membership the tool itself invented, not one the human set — the exact
/// self-bite the ruling this file exists for is meant to prevent.
///
/// Title-only, not identifier-based: `PHAssetCollection` exposes no custom
/// identifier through the public API, so this is a string match against
/// `snapsiftTitles`. KNOWN LIMITATION, stated rather than hidden: a user
/// album that happens to share one of these exact titles would also be
/// excluded. Accepted because the titles are namespaced with "Snapsift · "
/// specifically to make that collision unlikely.
public func userAlbumCount(titles: [String], snapsiftTitles: Set<String>) -> Int {
    titles.filter { !snapsiftTitles.contains($0) }.count
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
    /// The freshness probe could not run AT ALL (the database was locked —
    /// SQLITE_BUSY while Photos writes — or an IO error). We learned nothing.
    ///
    /// Distinct from `.staleContents` on purpose: that one is a POSITIVE
    /// finding ("assets PhotoKit can see are missing from this file"), and
    /// telling the user their library file looks frozen when the truth is
    /// "Photos was busy for two seconds" is a banner that invents a fact.
    /// Both are untrusted for this sweep; only one of them is news.
    case probeUnavailable
}

/// Decide whether the sidecar database may be trusted for PROTECTION facts.
///
/// `sampledNewest` / `foundInSidecar`: the N most recently created assets as
/// PhotoKit reports them, and how many of those the sidecar knows. A database
/// at the right path but frozen (an old copy, a restored snapshot) fails here.
/// `foundInSidecar == nil` means THE PROBE ITSELF FAILED (database busy, IO
/// error) — we learned nothing, which is `.probeUnavailable`, not "stale".
///
/// WHAT `photosLibraryPath` ACTUALLY IS, stated because the guarantee depends
/// on it: the caller resolves Photos' own `IPXDefaultLibraryURLBookmark`, which
/// is the library Photos.app LAST OPENED — not, provably, the System Photo
/// Library that PhotoKit serves. They are the same on every ordinary Mac, and
/// they diverge for a user who opened a second library (⌥-launch) once. There
/// is no public PhotoKit API for the served library's URL (`PHPhotoLibrary`
/// exposes none), so the path check is the cheap half of the identity proof and
/// the freshness probe below is the half that catches a divergence: a library
/// Photos merely opened once is missing everything imported since. Where the
/// probe cannot run, we say we could not check — we never upgrade a guess.
///
/// Anything short of a positive answer is a MISMATCH, never a shrug: `edited`
/// then comes from the per-asset PhotoKit fallback, and where that fails too
/// the frame is undetermined ⇒ protected, with a banner saying so.
public func evaluateLibraryIdentity(sidecarPath: String?,
                                    photosLibraryPath: String?,
                                    sampledNewest: Int = 0,
                                    foundInSidecar: Int? = 0) -> LibraryIdentity {
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
    if sampledNewest > 0 {
        guard let foundInSidecar else { return .unverified(.probeUnavailable) }
        if foundInSidecar < sampledNewest { return .unverified(.staleContents) }
    }
    return .verified
}

// MARK: - Snapsift's own albums: one bucket per frame, across scans

/// Which frames go into "Exact Duplicates" and "Needs a look" THIS pass, and
/// which have to come OUT of the other one.
///
/// The two buckets are mutually exclusive within a single write
/// (`exactCandidates` filters on `isDeletable`, `needsLookCandidates` on
/// `isUnverifiable`), but the album write USED TO be add-only and never
/// recomputed what it wrote last time. So a frame filed under "Exact
/// Duplicates" (which the UI and the README call safe to remove) on a run with
/// Full Disk Access reappears under "Needs a look" on a run without it, and
/// Photos.app — the surface this tool deliberately delegates the decision to —
/// shows the same photo carrying two labels that contradict each other.
///
/// Removing an asset from an album snapsift created is membership-only and
/// destroys nothing (`PHAssetCollectionChangeRequest.removeAssets`); the photo
/// stays in the library and in every album the USER filed it into. Only
/// snapsift's own albums are ever touched.
///
/// If the two inputs ever overlap (they must not), NEEDS-A-LOOK WINS: a frame
/// we could not classify must never be the one wearing the "safe to remove"
/// label.
public struct AlbumBucketPlan: Equatable {
    /// Frames to add to "Snapsift · Exact Duplicates".
    public let exactAdd: [String]
    /// Frames to add to "Snapsift · Needs a look".
    public let needsLookAdd: [String]
    /// Frames to take OUT of "Snapsift · Exact Duplicates": they belong in
    /// Needs-a-look now, or this scan re-evaluated them and no longer files
    /// them as exact (`albumMembershipRemovals`).
    public let exactRemove: Set<String>
    /// Frames to take OUT of "Snapsift · Needs a look": they are classifiable
    /// again and belong in Exact Duplicates, or this scan re-evaluated them
    /// and they are readable now.
    public let needsLookRemove: Set<String>
}

/// `exactWorkingSet` / `needsLookWorkingSet` — what THIS scan re-evaluated for
/// each album (`albumWorkingSet`). Empty (the default) ⇒ the old add-only
/// behaviour plus cross-bucket exclusivity.
public func albumBucketPlan(exactCandidates: [String],
                            needsLookCandidates: [String],
                            exactWorkingSet: Set<String> = [],
                            needsLookWorkingSet: Set<String> = []) -> AlbumBucketPlan {
    let needsLook = Set(needsLookCandidates)
    // Overlap is a bug upstream; resolve it in the protective direction here
    // rather than letting both albums claim the frame.
    let exact = exactCandidates.filter { !needsLook.contains($0) }
    return AlbumBucketPlan(
        exactAdd: exact,
        needsLookAdd: needsLookCandidates,
        exactRemove: needsLook.union(albumMembershipRemovals(workingSet: exactWorkingSet,
                                                             candidates: exact)),
        needsLookRemove: Set(exact).union(albumMembershipRemovals(workingSet: needsLookWorkingSet,
                                                                  candidates: needsLookCandidates)))
}

// MARK: - Snapsift's own albums: authoritative over what the scan looked at

/// A snapsift-owned album is authoritative per sort ONLY OVER WHAT THE SCAN
/// LOOKED AT: a member comes out when this scan re-evaluated it (`workingSet`)
/// and no longer puts it there. A member the scan never looked at stays
/// exactly where it is. The writer removes only ids that are actually members
/// (`AlbumWriter.removeAssets` intersects with the album), so this is the set
/// of ids that MAY come out, never a set that is added anywhere.
///
/// Two failures, one on each side of this rule:
///   • add-only (before 2026-10-13, check F1): {A keeper, B} sorted put B in
///     "Exact Duplicates"; the owner chose B as keeper and sorted again, which
///     added A and LEFT B — the album the README calls safe to remove held the
///     photo and its only other copy.
///   • authoritative over EVERYTHING (review P1-1 on the first fix): sorting
///     after a scan of one small album, or after a scan kind that has no exact
///     pass, took every other scan's results out of all five albums. They had
///     not been judged; they had not been seen.
///
/// Removal is membership-only (`PHAssetCollectionChangeRequest.removeAssets`)
/// and only from albums resolved by snapsift's own titles.
public func albumMembershipRemovals(workingSet: Set<String>, candidates: [String]) -> Set<String> {
    workingSet.subtracting(candidates)
}

/// The frames of ONE exact-duplicate group that may sit in the album labelled
/// "safe to remove": not the keeper, and deletable (`Photo.isDeletable` — the
/// same predicate the delete pipeline uses).
///
/// A group whose `keeperID` names no frame in it contributes NOTHING. Without
/// that, "everything that is not the keeper" is every frame of the group, and
/// the album would hold all copies of a photo — the one state it must never be
/// in. Unknown keeper ⇒ nobody is a candidate.
public func exactAlbumCandidates(photos: [Photo], keeperID: String) -> [String] {
    guard isGroupMember(keeperID, of: photos) else { return [] }
    return photos.filter { $0.uuid != keeperID && $0.isDeletable }.map(\.uuid)
}

/// Snapsift's five albums.
public enum AlbumBucket: CaseIterable, Equatable {
    case bursts, blurry, documents, exact, needsLook
}

/// The kind of scan that produced the groups being sorted. Raw values match
/// `PhotoLibrarySession.ScanKind`, so the session converts by raw value, not by
/// a switch that could quietly map two kinds onto one.
public enum AlbumScanKind: String, CaseIterable {
    case burst, lookAlikes, similarSets
}

/// Does a scan of this kind PRODUCE verdicts for this album?
///
/// Burst and look-alike scans build review groups and run the exact-duplicate
/// pass over every one of them, so they feed all five. A similar-sets scan
/// builds sets (browsed on macOS; reviewed and removed through
/// `deleteReviewed(in:)` on a session without an enrichment port) and never
/// writes an album: no review groups, no exact pass. It decides nothing about
/// any of these albums, so a sort after it may add (the Live Photo videos it
/// could not pair still go to Needs-a-look) and removes NOTHING. An unknown
/// kind (nil) is treated the same way.
public func scanKindFeeds(_ kind: AlbumScanKind?, _ bucket: AlbumBucket) -> Bool {
    switch kind {
    case .burst?, .lookAlikes?: return true
    case .similarSets?, nil:    return false
    }
}

/// The asset ids this scan re-evaluated FOR THIS ALBUM — the only members a
/// sort may take out of it.
///
/// No scan kind keeps a record of every asset it examined: the full-library
/// map is trimmed to group members the moment a scan ends. What survives, and
/// what a verdict was actually reached about, is the frames of the current
/// review groups — so that is the working set, for the kinds that feed the
/// album (`scanKindFeeds`), and EMPTY for a kind that does not. The asset-only
/// needs-look extras belong to that album's working set too (they are always
/// candidates, so this never removes one; it only keeps the set truthful).
public func albumWorkingSet(_ bucket: AlbumBucket,
                            scanKind: AlbumScanKind?,
                            groupPhotoIDs: [String],
                            extraNeedsLookIDs: [String] = []) -> Set<String> {
    guard scanKindFeeds(scanKind, bucket) else { return [] }
    var ids = Set(groupPhotoIDs)
    if bucket == .needsLook { ids.formUnion(extraNeedsLookIDs) }
    return ids
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
