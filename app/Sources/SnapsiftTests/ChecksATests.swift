import Foundation
import Photos
import SnapsiftCore
import SnapsiftFolder
@testable import SnapsiftPhotoKit

// Check round 2026-10-11 (PR #5), restacked onto the shared Photos session and
// Folder Mode: album membership authoritative per sort, journal reconcile
// gated on Photos access and merged rather than overwritten, the promote
// membership guard, the ⌘/⌃/⌥ verb gate, and ⇧K's undo. No Photos library is
// read, nothing is deleted, no album is written: albums are a synthetic double.

/// Albums as sets, keyed by title. Behaves like the PhotoKit operations do:
/// add skips present members, remove takes out only ids that ARE members.
private final class AlbumStateOperations: AlbumWriter.Operations {
    var albums: [String: Set<String>]
    init(_ albums: [String: Set<String>] = [:]) { self.albums = albums }

    func add(_ assetIDs: [String], toAlbumNamed name: String,
             candidateTitles: [String]) async throws -> Int {
        let key = candidateTitles.first { albums[$0] != nil } ?? name
        let current = albums[key] ?? []
        let new = Set(assetIDs).subtracting(current)
        albums[key] = current.union(new)
        return new.count
    }

    func remove(ids: Set<String>, fromAlbumTitles candidateTitles: [String]) async throws -> Int {
        var removed = 0
        for title in candidateTitles {
            guard let current = albums[title] else { continue }
            removed += current.intersection(ids).count
            albums[title] = current.subtracting(ids)
        }
        return removed
    }
}

private final class ChecksANoImageManager: PHCachingImageManager, @unchecked Sendable {}

@MainActor
func checkChecksA() async {
    await checkAlbumsAuthoritative()
    checkJournalReconcile()
    checkVerbActions()
    checkSessionAndFolderVerbs()
}

// MARK: - 1. Albums: authoritative over what the scan looked at

@MainActor
private func checkAlbumsAuthoritative() async {
    print("Snapsift albums: authoritative over what the scan looked at (F1, review P1-1)")
    let titles = testAlbumTitles()
    let names: [AlbumBucket: String] = [
        .bursts: titles.bursts.name, .blurry: titles.blurry.name, .documents: titles.documents.name,
        .exact: titles.exact.name, .needsLook: titles.needsLook.name,
    ]
    typealias Albums = [AlbumBucket: Set<String>]
    /// One sort through the SAME AlbumWriter plan and execution the session
    /// runs, over the album double.
    func sort(_ groups: [ReviewGroup], exact: Set<ReviewGroup.ID>, kind: AlbumScanKind?,
              extras: [String] = [], _ albums: Albums) async -> (albums: Albums, moved: Int) {
        var byTitle: [String: Set<String>] = [:]
        for (bucket, ids) in albums { byTitle[names[bucket]!] = ids }
        let ops = AlbumStateOperations(byTitle)
        let available = Set(groups.flatMap { $0.photos.map(\.uuid) })
        let report = await AlbumWriter.writeReport(
            groups: groups, exactGroups: exact, availableAssetIDs: available,
            extraNeedsLookIDs: extras, scanKind: kind, titles: titles, operations: ops)
        var out: Albums = [:]
        for (bucket, name) in names { out[bucket] = ops.albums[name] ?? [] }
        return (out, report.moved)
    }
    func group(_ photos: [Photo], keeper: String) -> ReviewGroup {
        ReviewGroup(photos: photos, keeperID: keeper)
    }
    /// The two things the album labelled "safe to remove" must never be.
    func invariantHolds(_ groups: [ReviewGroup], _ albums: Albums) -> Bool {
        let exact = albums[.exact] ?? []
        return groups.allSatisfy { g in
            !exact.contains(g.keeperID) && !g.photos.allSatisfy { exact.contains($0.uuid) }
        }
    }

    // 1. THE scenario: {U1 keeper, U2} sorted; the owner picks U2; sorted again.
    let pair = [ph(1, 0), ph(2, 1)]
    var g = group(pair, keeper: "U1")
    var state = await sort([g], exact: [g.id], kind: .burst, [:])
    check(state.albums[.exact] == ["U2"] && state.moved == 0, "first sort: the non-keeper copy is filed")
    g.keeperID = "U2"
    state = await sort([g], exact: [g.id], kind: .burst, state.albums)
    check(state.albums[.exact] == ["U1"],
          "keeper flipped, sorted again ⇒ album = {old keeper}; the new keeper LEFT it")
    check(state.moved == 1, "…and that one removal is what the banner counts")
    check(invariantHolds([g], state.albums), "the album never holds a group's keeper, nor every frame of a group")
    let afterFlip = state.albums
    // NEGATIVE CONTROL: the add-only writer (scan kind nil) leaves both copies.
    let addOnly = await sort([g], exact: [g.id], kind: nil, [.exact: ["U2"]])
    check(addOnly.albums[.exact] == ["U1", "U2"],
          "control: without a feeding scan kind the old add-only behaviour returns (both copies filed)")

    // 2. A similar-sets scan (no review groups, no exact pass) or an unknown
    //    kind, then sort: nothing leaves any album, and it still adds.
    let filed: Albums = [.exact: ["U1", "E9"], .bursts: ["B9"], .blurry: ["L9"],
                         .documents: ["D9"], .needsLook: ["N9"]]
    let sets = await sort([], exact: [], kind: .similarSets, extras: ["V1"], filed)
    check(sets.moved == 0 && sets.albums[.exact] == ["U1", "E9"] && sets.albums[.bursts] == ["B9"]
            && sets.albums[.blurry] == ["L9"] && sets.albums[.documents] == ["D9"],
          "similar-sets scan + sort ⇒ 0 removals; every album exactly as it was")
    check(sets.albums[.needsLook] == ["N9", "V1"],
          "…and it still ADDS what it owes (the unpaired Live Photo video)")
    for kind in [AlbumScanKind.similarSets, nil] {
        let hostile = await sort([group(pair, keeper: "U2")], exact: [], kind: kind, afterFlip)
        check(hostile.albums[.exact]?.contains("U1") == true && hostile.moved == 0,
              "kind \(kind.map { $0.rawValue } ?? "unknown") removes nothing, groups or not")
    }
    for bucket in AlbumBucket.allCases {
        check(scanKindFeeds(.burst, bucket) && scanKindFeeds(.lookAlikes, bucket)
                && !scanKindFeeds(.similarSets, bucket) && !scanKindFeeds(nil, bucket),
              "\(bucket): fed by burst and look-alike scans only")
    }
    for kind in [PhotoLibrarySession.ScanKind.burst, .lookAlikes, .similarSets] {
        check(AlbumScanKind(rawValue: kind.rawValue)?.rawValue == kind.rawValue,
              "session scan kind \(kind.rawValue) converts to the album scan kind by raw value")
    }

    // 3. The scan looked at the group and no longer calls it exact: out of
    //    "safe to remove", into the review album.
    let demoted = await sort([group(pair, keeper: "U2")], exact: [], kind: .lookAlikes, afterFlip)
    check(demoted.albums[.exact]!.isEmpty && demoted.albums[.bursts] == ["U1"] && demoted.moved == 1,
          "group no longer exact ⇒ out of Exact Duplicates, into the review album")

    // 4. Narrow scope: members the scan never looked at stay, in every album.
    let wide: Albums = [.exact: ["U2", "OUT1", "OUT2"], .bursts: ["OUT3"],
                        .documents: ["OUT4"], .needsLook: ["OUT5"], .blurry: ["OUT6"]]
    let flipped = group(pair, keeper: "U2")
    let narrow = await sort([flipped], exact: [flipped.id], kind: .burst, wide)
    check(narrow.albums[.exact] == ["U1", "OUT1", "OUT2"],
          "narrow scan: the re-evaluated frame is corrected, out-of-scope members stay")
    check(narrow.albums[.bursts] == ["OUT3"] && narrow.albums[.documents] == ["OUT4"]
            && narrow.albums[.needsLook] == ["OUT5"] && narrow.albums[.blurry] == ["OUT6"],
          "…in all five albums")
    check(narrow.moved == 1 && invariantHolds([flipped], narrow.albums),
          "…the banner counts only what this scan re-evaluated, and the invariant holds")

    // 5. Every other way a member stops being a candidate between two sorts.
    let three = [ph(1, 0), ph(2, 1), ph(3, 2)]
    let g3 = group(three, keeper: "U1")
    let before = await sort([g3], exact: [g3.id], kind: .burst, [.exact: ["OUT1"]])
    check(before.albums[.exact] == ["U2", "U3", "OUT1"], "three copies: the two non-keepers are filed")
    let cases: [(String, ReviewGroup, Bool, Set<String>)] = [
        ("a filed copy was starred since",
         group([ph(1, 0), ph(2, 1, fav: true), ph(3, 2)], keeper: "U1"), true, ["U3"]),
        ("a filed copy was edited since",
         group([ph(1, 0), ph(2, 1), ph(3, 2, edited: true)], keeper: "U1"), true, ["U2"]),
        ("a filed copy can no longer be read",
         group([ph(1, 0), ph(2, 1, editedUnknown: true), ph(3, 2)], keeper: "U1"), true, ["U3"]),
        ("the group is no longer an exact duplicate", group(three, keeper: "U1"), false, []),
        ("the keeper names no frame of the group", group(three, keeper: "GONE"), true, []),
        ("the keeper moved to a filed copy", group(three, keeper: "U3"), true, ["U1", "U2"]),
    ]
    for (label, cg, isExact, expected) in cases {
        let after = await sort([cg], exact: isExact ? [cg.id] : [], kind: .burst, before.albums)
        check(after.albums[.exact] == expected.union(["OUT1"]),
              "\(label) ⇒ album = \(expected.sorted()) + the out-of-scope member")
        check(invariantHolds([cg], after.albums), "\(label) ⇒ invariant holds")
    }
    check(exactAlbumCandidates(photos: three, keeperID: "GONE").isEmpty
            && exactAlbumCandidates(photos: three, keeperID: "U1") == ["U2", "U3"],
          "an exact group whose keeper names no frame files nothing as safe to remove")

    // 6. The review albums reconcile through the same plan.
    //    U10 keeper (sharp), U11 soft, U12 favorite, U13 document, U14 unreadable.
    let mixed = [ph(10, 0, sharpness: 5), ph(11, 1, sharpness: 1), ph(12, 2, fav: true, sharpness: 9),
                 ph(13, 3, isDocument: true), ph(14, 4, docDegraded: true)]
    var mg = group(mixed, keeper: "U10")
    let first = await sort([mg], exact: [], kind: .burst, [:]).albums
    check(first[.bursts]?.contains("U11") == true && first[.blurry]?.contains("U11") == true
            && first[.documents] == ["U13"] && first[.needsLook] == ["U14"] && first[.exact]!.isEmpty,
          "fixture: each review album gets its own, a non-exact group files nothing as exact")
    mg.keeperID = "U11"
    let renominated = await sort([mg], exact: [], kind: .lookAlikes, first)
    check(renominated.albums[.bursts]?.contains("U11") == false
            && renominated.albums[.bursts]?.contains("U10") == true,
          "bursts: the new keeper leaves the review album, the old one enters")
    check(renominated.albums[.blurry]?.contains("U11") == false,
          "blurry: the new keeper is not 'the blurry one' any more")
    check(renominated.moved >= 2, "…and both removals are counted")

    // The rule itself.
    check(albumMembershipRemovals(workingSet: ["A", "B", "D"], candidates: ["B", "D"]) == ["A"],
          "removals = looked-at − candidates (the writer intersects with actual members)")
    check(albumMembershipRemovals(workingSet: [], candidates: []).isEmpty, "nothing looked at ⇒ nothing removed")
    check(albumWorkingSet(.needsLook, scanKind: .burst, groupPhotoIDs: ["A"], extraNeedsLookIDs: ["V"]) == ["A", "V"]
            && albumWorkingSet(.exact, scanKind: .burst, groupPhotoIDs: ["A"], extraNeedsLookIDs: ["V"]) == ["A"]
            && albumWorkingSet(.exact, scanKind: .similarSets, groupPhotoIDs: ["A"]).isEmpty,
          "working set = this scan's group frames (+ unpaired videos for Needs a look); empty for similar sets")
    // NEGATIVE CONTROLS (run 2026-10-14 on this restack, one at a time):
    // `albumMembershipRemovals` returns [] ⇒ 16 rows red (sections 1, 3, 4,
    // 5, 6); `scanKindFeeds` returns true ⇒ 11 red (the control, the "removes
    // nothing" rows, the per-album feed rows); no `isGroupMember` guard in
    // `exactAlbumCandidates` ⇒ 3 red ("keeper names no frame").
}

// MARK: - 2. Journal: cannot see ≠ gone; merged, never overwritten

@MainActor
private func checkJournalReconcile() {
    print("Journal reconcile: cannot see ≠ gone (check 2026-10-11 F2)")
    func rec(_ id: String) -> DeletionRecord {
        DeletionRecord(timestamp: "2026-10-13T00:00:00Z", assetIdentifier: id,
                       filename: "\(id).heic", sizeBytes: 1, keeperIdentifier: "K",
                       keeperFilename: "K.heic", reason: .userRejected)
    }
    let intent = DeletionSession(timestamp: "2026-10-13T00:00:00Z", records: [rec("A"), rec("B"), rec("C")])
    // (PHAuthorizationStatus raw value, fetch result, already logged) → booked ids, nil = defer.
    let table: [(String, Int, Set<String>, Set<String>, [String]?)] = [
        ("0 notDetermined", 0, [], [], nil),
        ("1 restricted", 1, [], [], nil),
        ("2 denied", 2, [], [], nil),
        ("4 limited, fetch would return a subset", 4, ["A"], [], nil),
        ("99 unknown status", 99, ["A", "B", "C"], [], nil),
        ("3 authorized, all three missing", 3, [], [], ["A", "B", "C"]),
        ("3 authorized, all three present (confirmation was cancelled)", 3, ["A", "B", "C"], [], []),
        ("3 authorized, B present, C already logged", 3, ["B"], ["C"], ["A"]),
    ]
    for (label, raw, existing, logged, expected) in table {
        var fetches = 0
        let result = DeletionAuditLog.journalReconcile(
            intent: intent, access: DeletionAuditLog.PhotoAccess(photoKitRawValue: raw),
            alreadyLogged: logged, stillExisting: { fetches += 1; return existing })
        var got: [String]? = nil
        if case .book(let records) = result { got = records.map(\.assetIdentifier) }
        check(got == expected, "\(label) ⇒ \(expected.map { "book \($0)" } ?? "DEFER, journal kept")")
        check(fetches == (expected == nil ? 0 : 1),
              "\(label) ⇒ library \(expected == nil ? "NOT asked" : "asked once")")
    }
    check(PHAuthorizationStatus.authorized.rawValue == 3 && PHAuthorizationStatus.limited.rawValue == 4
            && PHAuthorizationStatus.denied.rawValue == 2,
          "the raw values the access table assumes are PhotoKit's own")

    // The store the session reconciles through: deferred keeps the journal.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-checks-a-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let storage = PhotoLibraryStorage(directory: tmp)
    let store = PhotoLibraryHistoryStore(storage: storage)
    func pending() -> [String] {
        DeletionAuditLog.pendingIntent(at: storage.journalURL)?.records.map(\.assetIdentifier) ?? []
    }
    func historyIDs() -> Set<String> { DeletionAuditLog.loggedAssetIdentifiers(from: store.loadSessions()) }
    let old = DeletionSession(timestamp: "2026-10-12T00:00:00Z", records: [rec("A"), rec("B")])
    let next = DeletionSession(timestamp: "2026-10-13T00:00:00Z", records: [rec("C"), rec("D")])
    _ = DeletionAuditLog.writeIntent(old, to: storage.journalURL)
    var asked = false
    check(store.reconcile(access: .limited) { _ in asked = true; return [] } == nil
            && !asked && pending() == ["A", "B"] && historyIDs().isEmpty,
          "limited access: reconcile defers, never fetches, books nothing, keeps the journal")

    // A deferred journal must survive the NEXT commit, through the PhotoKit ports.
    for (label, committed) in [("the new commit succeeds", true), ("the new commit is cancelled", false)] {
        try? FileManager.default.removeItem(at: tmp)
        _ = DeletionAuditLog.writeIntent(old, to: storage.journalURL)   // interrupted, deferred at launch
        let ports = PhotoKitCommitPorts.make(storage: storage, editedNow: { _ in [:] })
        check(ports.writeIntent(next) && pending() == ["A", "B", "C", "D"],
              "\(label): writeIntent ADDS to an unreconciled journal, never replaces it")
        if committed { _ = ports.appendAudit(next) }
        ports.clearIntent()                                             // the commit is done with the journal
        check(pending() == ["A", "B"], "\(label): the earlier batch is still journalled afterwards")
        let booked = store.reconcile(access: .authorized) { _ in committed ? [] : ["C", "D"] }
        check(booked == 2, "\(label): the next reconcile with full access books the earlier batch")
        check(historyIDs() == (committed ? ["A", "B", "C", "D"] : ["A", "B"]) && pending().isEmpty,
              "\(label): \(committed ? "BOTH batches end" : "the earlier batch ends") in the history; journal cleared")
    }
    // A commit that journalled nothing must not clear someone else's journal.
    try? FileManager.default.removeItem(at: tmp)
    _ = DeletionAuditLog.writeIntent(old, to: storage.journalURL)
    PhotoKitCommitPorts.make(storage: storage, editedNow: { _ in [:] }).clearIntent()
    check(pending() == ["A", "B"], "ports that wrote no intent leave an earlier journal in place")
    check(DeletionAuditLog.mergedIntent(pending: nil, new: next).records.count == 2
            && DeletionAuditLog.intentRemaining(pending: next, settled: next) == nil,
          "no earlier journal ⇒ plain write, and settling clears it")
    let overlap = DeletionAuditLog.mergedIntent(
        pending: old, new: DeletionSession(timestamp: "t", records: [rec("B"), rec("C")]))
    check(overlap.records.map(\.assetIdentifier) == ["A", "B", "C"], "a photo named by both is journalled once")
    // NEGATIVE CONTROLS (run 2026-10-14, one at a time): no
    // `seesWholeLibrary` guard ⇒ 11 red (the non-authorized rows, twice each,
    // and the limited-store row); `writeIntent` encodes `session` instead of
    // the merge ⇒ 8 red; the ports' clearIntent calls `clearIntent(at:)` ⇒ 7
    // red (the "still journalled" rows and what follows from them).
}

// MARK: - 3–5. Verbs as Core actions

private func checkVerbActions() {
    print("Verbs as Core actions: K, ⇧K, D, and which key presses may be verbs")
    // U1 U2 U5 plain, U3 favorite, U4 unreadable.
    let photos = [ph(1, 0), ph(2, 1), ph(3, 2, fav: true), ph(4, 3, docDegraded: true), ph(5, 4)]
    func snap(_ keeper: String, _ rejected: Set<String>, seeded: Set<String> = [],
              override: Bool = false) -> GroupMarkSnapshot {
        GroupMarkSnapshot(keeperID: keeper, rejected: rejected, autoSeeded: seeded, includeProtected: override)
    }

    // K / 1–9
    check(nominateAction(photos: photos, current: snap("U1", ["U2"]), to: "U9") == nil,
          "K on a uuid that is not in the group ⇒ no action at all")
    check(nominateAction(photos: photos, current: snap("U1", ["U2"]), to: "") == nil
            && nominateAction(photos: [], current: snap("U1", []), to: "U1") == nil,
          "empty id / empty group ⇒ no action")
    check(nominateAction(photos: photos, current: snap("U1", ["U2", "U5"], seeded: ["U2", "U5"]), to: "U2")
            == snap("U2", ["U5"], seeded: ["U5"]),
          "K: keeper := frame, that frame un-marked (and its provenance), nothing else")
    check(nominateAction(photos: photos, current: snap("U1", ["U3"], override: true), to: "U3")
            == snap("U3", [], override: false),
          "K on the only force-marked favorite drops the ⇧X override with it")
    check(nominateAction(photos: photos, current: snap("U1", ["U3", "U2"], override: true), to: "U2")
            == snap("U2", ["U3"], override: true),
          "…but keeps it while a protected frame is still marked")

    // D
    let d = rejectAllAction(photos: photos, current: snap("U1", ["U3"], seeded: ["U3"], override: true))
    check(d?.state == snap("U1", ["U2", "U5"]),
          "D: every deletable non-keeper, provenance cleared, and the override switched OFF")
    check(d?.withheld == 1, "D reports the unreadable frame it left out")
    check(rejectAllAction(photos: photos, current: snap("GONE", []))?.state.rejected == ["U2", "U5"],
          "D with a keeper that names no frame spares the first frame, as before")
    check(rejectAllAction(photos: [], current: snap("U1", [])) == nil, "D on an empty group ⇒ no action")

    // ⇧K and its undo
    check(keepOnlyAction(photos: photos, current: snap("U1", []), undo: nil, frameID: "U9") == nil,
          "⇧K on a uuid that is not in the group ⇒ no action")
    func press(_ frame: String, _ cur: GroupMarkSnapshot, _ undo: KeepOnlyUndo?)
        -> (state: GroupMarkSnapshot, undo: KeepOnlyUndo?, undone: Bool) {
        switch keepOnlyAction(photos: photos, current: cur, undo: undo, frameID: frame) {
        case .undone(let back)?:             return (back, nil, true)
        case .applied(let after, let keep)?: return (after, keep, false)
        case nil:                            return (cur, undo, false)
        }
    }
    let starts = [
        snap("U1", []),
        snap("U1", ["U2"], seeded: ["U2"]),
        snap("U1", ["U3"], override: true),   // ⇧X'd favorite, then ⇧K by mistake
        snap("U5", ["U1", "U2"], seeded: ["U1", "U2"]),
    ]
    for start in starts {
        for frame in ["U2", "U3", "U5"] {
            let once = press(frame, start, nil)
            let twice = press(frame, once.state, once.undo)
            if once.state == start {
                check(once.undo == nil && !twice.undone && twice.state == start,
                      "⇧K on \(frame) from \(start.keeperID)/\(start.rejected.sorted()) is a no-op ⇒ no undo recorded, no 'restored' banner")
            } else {
                check(twice.undone && twice.state == start && twice.undo == nil,
                      "⇧K ⇧K on \(frame) from \(start.keeperID)/\(start.rejected.sorted()) ⇒ exactly the state before")
            }
        }
    }
    let first = press("U2", starts[0], nil)
    check(first.state.rejected == ["U1", "U5"], "(fixture) ⇧K on U2 marks the other deletable frames")
    check(!press("U5", first.state, first.undo).undone, "⇧K on a DIFFERENT frame is a new nomination, not an undo")
    let touched = snap(first.state.keeperID, first.state.rejected.subtracting(["U5"]))
    check(keepOnlyUndoTarget(current: touched, undo: first.undo, frameID: "U2", photos: photos) == nil,
          "a mark changed since ⇒ no undo (a stale 'before' is never restored)")
    check(keepOnlyUndoTarget(current: first.state, undo: first.undo, frameID: "U2",
                             photos: photos.filter { $0.uuid != "U1" }) == nil,
          "the remembered keeper is no longer in the group ⇒ no undo")
    let prov = press("U2", starts[3], nil).state
    check(prov.rejected == ["U1", "U5"] && prov.autoSeeded == ["U1"],
          "⇧K keeps `autoSeeded` on the seeded mark it left standing, and only there")

    // Which key presses may be verbs — the gate both Photos and Folder views use.
    let keys: [(Bool, Bool, Bool, Bool)] = [
        (false, false, false, true),
        (true, false, false, false), (false, true, false, false), (false, false, true, false),
        (true, true, false, false), (true, false, true, false), (false, true, true, false),
        (true, true, true, false),
    ]
    for (cmd, ctrl, opt, expected) in keys {
        for shift in [false, true] {
            let p = VerbKeyPress(command: cmd, control: ctrl, option: opt, shift: shift, isRepeat: false)
            check((p != nil) == expected,
                  "⌘\(cmd ? 1 : 0) ⌃\(ctrl ? 1 : 0) ⌥\(opt ? 1 : 0) ⇧\(shift ? 1 : 0) ⇒ \(expected ? "verb" : "ignored")")
        }
    }
    func keep(shift: Bool, isRepeat: Bool) -> VerbKeyPress.KeepVerb? {
        VerbKeyPress(command: false, control: false, option: false, shift: shift, isRepeat: isRepeat)?.keepVerb
    }
    check(keep(shift: false, isRepeat: false) == .nominate && keep(shift: false, isRepeat: true) == .nominate,
          "K, held or not, nominates")
    check(keep(shift: true, isRepeat: false) == .keepOnly, "⇧K pressed ⇒ keep only")
    check(keep(shift: true, isRepeat: true) == .swallow, "⇧K HELD ⇒ swallowed: auto-repeat never toggles the undo")
    // NEGATIVE CONTROLS (run 2026-10-14, one at a time): no `isGroupMember`
    // guard in nominateAction ⇒ 3 red (both Core rows and the Photos session
    // row); `!option` dropped from isPlainVerbKey ⇒ the 2 ⌥-only rows red;
    // `.undone` never returned ⇒ 15 red; `isRepeat ? .swallow :` dropped ⇒
    // the ⇧K HELD row red.
}

// MARK: - The same verbs through the Photos session and Folder Mode

@MainActor
private func checkSessionAndFolderVerbs() {
    print("Promote guard and ⇧K undo on both paths (Photos session, Folder review state)")
    let photos = [ph(1, 0), ph(2, 1), ph(3, 2, fav: true), ph(5, 4)]

    // Photos: the shared session.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-checks-a-s-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let title = PhotoLibraryAlbumTitle(name: "fixture", candidateTitles: [])
    let session = PhotoLibrarySession(storage: PhotoLibraryStorage(directory: tmp),
        albumTitles: .init(bursts: title, blurry: title, documents: title, exact: title, needsLook: title),
        imageManager: ChecksANoImageManager())
    var g = ReviewGroup(photos: photos, keeperID: "U1")
    g.rejected = ["U2"]
    g.autoSeeded = ["U2"]
    session.groups = [g]
    session.promote(group: g.id, to: "FOREIGN")
    check(session.groups[0].keeperID == "U1" && session.groups[0].rejected == ["U2"],
          "Photos: promote to a frame outside the group changes nothing")
    session.promote(group: g.id, to: "U2")
    check(session.groups[0].keeperID == "U2" && session.groups[0].rejected.isEmpty
            && session.groups[0].autoSeeded.isEmpty,
          "Photos: promote to a member nominates it and un-marks only it")
    session.promote(group: g.id, to: "U1")
    let beforeK = session.groups[0]
    check(!session.keepOnly(group: g.id, frame: "U2"), "Photos: first ⇧K applies (not an undo)")
    check(session.groups[0].keeperID == "U2" && session.groups[0].rejected == ["U1", "U5"],
          "Photos: ⇧K keeps U2 and crosses out the other deletable frames")
    check(session.keepOnly(group: g.id, frame: "U2"), "Photos: ⇧K again on the same frame reports the undo")
    check(session.groups[0].keeperID == beforeK.keeperID && session.groups[0].rejected == beforeK.rejected
            && session.groups[0].autoSeeded == beforeK.autoSeeded
            && session.groups[0].includeProtected == beforeK.includeProtected,
          "Photos: …and the group is exactly as it was")
    _ = session.keepOnly(group: g.id, frame: "U2")
    _ = session.toggleReject(group: g.id, frameID: "U5")
    check(!session.keepOnly(group: g.id, frame: "U2") && session.groups[0].rejected == ["U1", "U5"],
          "Photos: a mark changed in between ⇒ ⇧K is a fresh ⇧K, not an undo")
    var fp = ReviewGroup(photos: photos, keeperID: "U1")
    fp.rejected = ["U3"]
    fp.includeProtected = true
    session.groups = [fp]
    _ = session.rejectAll(group: fp.id)
    check(session.groups[0].rejected == ["U2", "U5"] && !session.groups[0].includeProtected,
          "Photos: D leaves no ⇧X override standing with no protected photo marked")

    // Folder: the review state Folder Mode's session applies.
    let fg = ReviewGroup(photos: photos, keeperID: "U1")
    var folder = FolderReviewState(groups: [fg])
    check(!folder.apply(.promote("FOREIGN"), to: fg.id) && folder.groups[0].keeperID == "U1",
          "Folder: promote to a frame outside the group is refused (its own guard, verified)")
    let folderBefore = folder.groups[0]
    if case .applied? = folder.keepOnly("U2", in: fg.id) {
        check(folder.groups[0].keeperID == "U2" && folder.groups[0].rejected == ["U1", "U5"],
              "Folder: first ⇧K keeps U2 and crosses out the other deletable frames")
    } else { check(false, "Folder: first ⇧K applies") }
    if case .undone? = folder.keepOnly("U2", in: fg.id) {
        check(folder.groups[0].keeperID == folderBefore.keeperID && folder.groups[0].rejected == folderBefore.rejected
                && folder.groups[0].autoSeeded == folderBefore.autoSeeded,
              "Folder: ⇧K again on the same frame puts the group back exactly")
    } else { check(false, "Folder: ⇧K again on the same frame is the undo") }
    check(folder.apply(.keepOnly("U2"), to: fg.id) && folder.groups[0].rejected == ["U1", "U5"]
            && folder.apply(.keepOnly("U2"), to: fg.id) && folder.groups[0].rejected.isEmpty,
          "Folder: the `.keepOnly` action toggles through the same undo")
    check(folder.keepOnly("FOREIGN", in: fg.id) == nil, "Folder: ⇧K on a frame outside the group ⇒ nothing")
}
