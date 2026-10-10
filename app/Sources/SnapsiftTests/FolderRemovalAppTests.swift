import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore
import SnapsiftFolder
import SnapsiftAppSupport

@MainActor
func folderRemovalAppTests(_ check: (Bool, String) -> Void) async {
    print("Folder removal app presentation and state")
    let a = ph(930, 0), b = ph(931, 1), c = ph(932, 2, edited: true)
    var group = ReviewGroup(photos: [a, b, c], keeperID: a.uuid)
    group.rejected = [b.uuid, c.uuid]
    group.autoSeeded = [b.uuid]
    group.includeProtected = true
    group.confidentDupe = true
    var state = FolderReviewState(groups: [group])
    state.finishRemoval(removed: [b.uuid], failed: [c.uuid])
    check(state.groups.count == 1 && state.groups[0].photos.map(\.uuid) == [a.uuid, c.uuid],
          "folder partial commit removes successful IDs only")
    check(state.groups[0].keeperID == a.uuid && state.groups[0].id == group.id && state.groups[0].confidentDupe,
          "folder regroup preserves keeper, group identity and review verdict")
    check(state.groups[0].rejected == [c.uuid] && state.groups[0].autoSeeded.isEmpty && state.groups[0].includeProtected,
          "folder failed protected member retains its explicit mark and consent")
    state.finishRemoval(removed: [], failed: [c.uuid])
    check(state.groups[0].rejected == [c.uuid] && state.groups[0].includeProtected,
          "folder zero-success retry does not change failed review decisions")
    state.finishRemoval(removed: [c.uuid], failed: [])
    check(state.groups.isEmpty, "folder successful removal resolves the ordinary keeper singleton")

    var allMarked = ReviewGroup(photos: [a, b], keeperID: a.uuid)
    allMarked.rejected = [a.uuid, b.uuid]
    state = FolderReviewState(groups: [allMarked])
    state.finishRemoval(removed: [a.uuid], failed: [b.uuid])
    check(state.groups.count == 1 && state.groups[0].photos.map(\.uuid) == [b.uuid]
          && state.groups[0].keeperID == b.uuid && state.groups[0].deletionIDs == [b.uuid],
          "folder failed singleton remains visible and armed after no-survivor partial removal")
    state.finishRemoval(removed: [b.uuid], failed: [])
    check(state.groups.isEmpty, "folder retry removes a failed singleton after success")

    var rerank = ReviewGroup(photos: [a, b, c], keeperID: a.uuid)
    rerank.rejected = [a.uuid]
    state = FolderReviewState(groups: [rerank])
    state.finishRemoval(removed: [a.uuid], failed: [])
    check(state.groups[0].keeperID == keeper([b, c]).uuid && state.groups[0].rejected.isEmpty,
          "folder regroup delegates removed-keeper ranking to Core")
    var untouched = group
    untouched.rejected = []
    state = FolderReviewState(groups: [untouched, group])
    state.finishRemoval(removed: ["unrequested"], failed: [])
    check(state.groups[0].rejected.isEmpty && state.groups[1].rejected == group.rejected,
          "folder regroup leaves unrelated and keep-all groups unchanged")

    for operation in [FolderActivityState.Operation.reviewing, .committing, .puttingBack, .reconciling] {
        var activity = FolderActivityState()
        check(activity.begin(operation) && activity.isBusy, "folder activity locks \(operation)")
        check(!activity.begin(.committing) && !activity.begin(.puttingBack) && activity.operation == operation,
              "folder activity blocks commit and Put Back re-entry during \(operation)")
        activity.finish()
        check(!activity.isBusy && activity.begin(.puttingBack), "folder activity unlocks after \(operation)")
    }
    var activity = FolderActivityState()
    check(!activity.begin(.idle) && !activity.isBusy, "folder idle does not acquire the busy guard")

    let url = URL(fileURLWithPath: "/fixture/photo.jpg")
    let volume = VolumeKey(rawValue: "fixture-volume")
    let withdrawals: [FolderWithdrawalReason] = [
        .itemUnavailable("item"), .memberMissing(url), .identityChanged(url), .sizeChanged(url),
        .modificationDateChanged(url), .volumeUnavailable(volume), .hashUnavailable("item"),
        .hashMismatch("item"), .membersChanged("item"),
    ] + [VolumeCapabilityReason.networkVolume, .readOnly, .unsupportedFilesystemType, .signalsUnavailable]
        .map { .scanOnly(volume, $0) }
    let removalFailures: [FolderRemovalFailureReason] = [
        .trash("test detail"), .invalidTrashResult(nil), .invalidTrashResult(url), .journalWrite("test detail"),
        .rollbackFailed([url], "test detail"),
    ] + withdrawals.map { .liveCheck($0) }
    for language in Language.allCases {
        let t = L10n(language)
        for (index, reason) in withdrawals.enumerated() {
            check(!t.folderWithdrawal(reason).isEmpty && t.folderWithdrawalReport(2, reason: reason).contains("2"),
                  "folder withdrawal \(index) translated in \(language.rawValue)")
        }
        for (index, reason) in removalFailures.enumerated() {
            check(!t.folderRemovalFailure(reason).isEmpty, "folder failure \(index) translated in \(language.rawValue)")
        }
        for reason in FolderHistoryUnavailableReason.allCases {
            check(!t.folderHistoryUnavailable(reason).isEmpty, "folder availability \(reason) translated in \(language.rawValue)")
        }
        check(t.folderCommitError(CommitError.journalWriteFailed) == t.folderJournalFailed()
              && t.folderCommitError(CommitError.busy) == t.folderCommitBusy()
              && t.folderCommitError(FolderHistoryError.pendingIntent) == t.folderPendingIntent(),
              "folder blocked commits have specific translated reasons in \(language.rawValue)")
        let messages = [t.folderReviewEligible(2), t.folderReviewRemovalTitle(2), t.folderReviewRemovalSubtitle(128), t.folderVolumeTotal(2, bytes: 128),
                        t.folderExternalTrashSpace(), t.folderNoSurvivorWarning(1), t.folderNoSurvivorAcknowledge(),
                        t.folderNoSurvivorRow(), t.folderProtectedWarning(1), t.folderReviewWithdrawals(),
                        t.folderCommitting(), t.folderPuttingBack(), t.folderReconciling(), t.folderReviewing(),
                        t.folderMarkedCount(2), t.folderRemoved(2), t.folderNothingRemoved(), t.folderRemovalIncomplete(1),
                        t.folderOperationReportTitle(), t.folderNewlyProtected(1), t.folderUnverifiedKept(1),
                        t.folderKeeperMissing(1), t.folderSurvivorsMissing(1), t.folderStale(1), t.folderAuditFailed(),
                        t.folderCommitFailed("detail"), t.folderRecovered(2, unavailable: 1), t.folderReconcileFailed("detail"),
                        t.folderHistoryEmpty(), t.folderHistoryFailed("detail"), t.folderHistoryRefresh(), t.folderOriginalPath(),
                        t.folderTrashLocation(), t.folderPutBack(), t.folderPutBackDone(), t.folderPutBackConflict([url]),
                        t.folderPutBackParentMissing([url]), t.folderPutBackFailed("detail"),
                        t.folderPutBackPartial([url], detail: "detail"), t.folderPutBackPersistenceFailed("detail"),
                        t.folderMemberRestored()]
        check(messages.allSatisfy { !$0.isEmpty }, "folder new presentation messages present in \(language.rawValue)")
        check(t.folderPutBackConflict([url]).contains(url.path) && t.folderPutBackPartial([url], detail: "detail").contains(url.path),
              "folder conflict and partial-restore reports name affected paths in \(language.rawValue)")
    }
    check(Set(Language.allCases.map { L10n($0).folderHistoryUnavailable(.volumeNotMounted) }).count == 3,
          "folder availability messages use each selected language")
    check(L10n(.zhTW).folderPutBack() == "放回原處" && L10n(.zhTW).folderExternalTrashSpace().contains("垃圾桶"),
          "folder restore and space copy use Taiwan wording")

    // Generated fixture files and a fake Trash port only; never system Trash.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-app-\(UUID().uuidString)")
    let source = root.appendingPathComponent("source"), trash = root.appendingPathComponent("fake-trash")
    do {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let destination = CGImageDestinationCreateWithURL(source.appendingPathComponent(name) as CFURL,
                                                              UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
        let items = try FolderEnumerator.enumerate(root: source).items.map {
            $0.with(photo: $0.photo.with(documentEvalDegraded: false))
        }.sorted { $0.primary.url.path < $1.primary.url.path }
        var g = ReviewGroup(photos: items.map(\.photo), keeperID: items[0].id)
        g.rejected = Set(items.dropFirst().map(\.id))
        var projection = FolderReviewState(groups: [g])
        let store = FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                                       intentURL: root.appendingPathComponent("intent.json"))
        var failed: Set<String> = []
        let port = FolderTrashPort(trash: { url in
            if url.lastPathComponent == "c.jpg" { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(url, destination)
            return destination
        })
        let committer = FolderCommitter(history: store, trashPort: port)
        let protectedItems = items.map { $0.id == items[2].id ? $0.with(photo: $0.photo.with(edited: true)) : $0 }
        var fullyMarked = ReviewGroup(photos: protectedItems.map(\.photo), keeperID: items[0].id)
        fullyMarked.rejected = Set(items.map(\.id))
        fullyMarked.includeProtected = true
        let review = FolderRemovalReview(summary: committer.preCommitSummary(groups: [fullyMarked], items: protectedItems),
                                         groups: [fullyMarked])
        check(review.summary.itemCount == 3 && review.summary.totalBytes == items.reduce(0, { $0 + $1.photo.size }),
              "folder review displays the library summary item count and member size total")
        check(review.protectedCount == 1 && review.noSurvivorCount == 1,
              "folder review flags eligible forced protection and explicit no-survivor removal")
        let scanOnly = FolderCommitter(history: store, trashPort: port, volumeProbe: { _ in
            VolumeProbeResult(facts: VolumeFacts(isLocal: false, isReadOnly: false, mntRdOnly: false,
                                                fileSystemType: "smbfs", isRootFileSystem: false),
                              volumeKey: items[0].volumeKey, displayName: "Fixture NAS", volumeURL: source)
        })
        let withheld = FolderRemovalReview(summary: scanOnly.preCommitSummary(groups: [fullyMarked], items: protectedItems),
                                            groups: [fullyMarked])
        check(withheld.summary.itemCount == 3 && withheld.summary.eligibleItemIDs.isEmpty
              && withheld.summary.withdrawals.count == 1 && withheld.protectedCount == 0 && withheld.noSurvivorCount == 0,
              "folder scan-only review retains its totals and withdrawal without promising protected or no-survivor moves")
        let count = try await committer.commit(groups: [g], items: items, primaryHashes: [:],
            callbacks: FolderCommitCallbacks(onRemovalFailed: { failed.insert($0.itemID) },
                shared: CommitCallbacks(onGroupsChanged: { projection.groups = $0 },
                    onCommitted: { projection.finishRemoval(removed: Set($0.deletedIDs), failed: failed) })))
        check(count == 1 && failed == [items[2].id] && projection.groups[0].deletionIDs == [items[2].id],
              "folder fake-port commit feeds successful and failed IDs into the app projection")
        let entries = try store.entries()
        check(entries.count == 1 && entries[0].putBackAvailable, "folder history exposes Put Back after fake-port removal")
        let entry = entries[0], record = entry.record
        check(folderHistoryUnavailableReason(record, volumeKey: { _ in nil }) == .volumeNotMounted,
              "folder history distinguishes an unmounted volume")
        check(folderHistoryUnavailableReason(record, volumeKey: { _ in record.volumeKey }, readMember: { _ in nil },
                                             pathExists: { _ in false }) == .trashMissing,
              "folder history distinguishes an emptied Trash on a mounted volume")
        check(folderHistoryUnavailableReason(record, volumeKey: { _ in record.volumeKey }, readMember: { _ in nil },
                                             pathExists: { _ in true }) == .cannotVerify,
              "folder history does not claim unreadable files are gone")
        check(folderHistoryUnavailableReason(record, volumeKey: { _ in record.volumeKey },
                                             readMember: { _ in items[2].primary }) == .itemChanged,
              "folder history rejects a replacement Trash file")
        var unknown = record
        unknown.members[0].trashURL = nil
        check(folderHistoryUnavailableReason(unknown, volumeKey: { _ in record.volumeKey }) == .locationUnknown,
              "folder history describes a missing recorded Trash location")
        for (recordState, reason) in [(FolderRecordState.restored, FolderHistoryUnavailableReason.restored),
                                     (.restoring, .restoring), (.rollbackFailed, .incompleteRemoval),
                                     (.pending, .incompleteRemoval), (.locationUnknown, .locationUnknown)] {
            var altered = record
            altered.state = recordState
            check(folderHistoryUnavailableReason(altered) == reason, "folder history maps state \(recordState)")
        }
        try Data("conflict".utf8).write(to: record.members[0].originalURL)
        if case .conflict(let urls) = try store.putBack(entry.id, port: port) {
            check(urls == [record.members[0].originalURL], "folder fake-port Put Back reports a conflict path without overwrite")
        } else { check(false, "folder fake-port Put Back should conflict") }
        try FileManager.default.removeItem(at: record.members[0].originalURL)
        if case .restored = try store.putBack(entry.id, port: port) {
            check(FileManager.default.fileExists(atPath: record.members[0].originalURL.path), "folder fake-port Put Back restores original path")
        } else { check(false, "folder fake-port Put Back should restore") }
        check(try store.entries()[0].putBackAvailable == false, "folder restored entry no longer offers Put Back")
    } catch { check(false, "folder app fake-port integration fixture: \(error)") }
}
