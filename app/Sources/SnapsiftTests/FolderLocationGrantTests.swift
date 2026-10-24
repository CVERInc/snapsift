import Foundation
import SnapsiftCore
@testable import SnapsiftFolder

@MainActor
private final class LocationGrantFixture {
    let root: URL
    let storage: URL
    let folders: [URL]
    let items: [FolderItem]
    let groups: [ReviewGroup]
    var status: FolderLocationGrantStatus = .notAsked
    var usable = true
    var wrongRoot = false
    var active = 0
    var attempts = 0
    var events: [String] = []
    var scoped = true
    var trashCalls: [URL] = []
    var moves: [(URL, URL)] = []
    var failTrashAt: Int?
    var failMoveAt: Int?
    var scans = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-location-grant-\(UUID())")
        storage = root.appendingPathComponent("Containers/Shared/AppGroup/fixture/File Provider Storage")
        folders = [storage.appendingPathComponent("first"), storage.appendingPathComponent("second"),
                   root.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/picked")]
        var items: [FolderItem] = []
        var groups: [ReviewGroup] = []
        for (index, folder) in folders.enumerated() {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashRoot(at: folder)!, withIntermediateDirectories: true)
            var pair: [FolderItem] = []
            for name in ["keeper", "candidate"] {
                let url = folder.appendingPathComponent("\(index)-\(name).jpg")
                try Data("bytes for \(index)-\(name)".utf8).write(to: url)
                let member = try FolderMember.read(at: url)
                var members = [member]
                if index == 0 && name == "candidate" {
                    let companion = folder.appendingPathComponent("\(index)-\(name).mov")
                    try Data("motion".utf8).write(to: companion)
                    members.append(try FolderMember.read(at: companion))
                }
                let photo = Photo(uuid: url.path, filename: url.lastPathComponent, takenAt: Double(index),
                                  width: 16, height: 16, size: member.size, uti: "public.jpeg")
                pair.append(FolderItem(photo: photo, primary: member, members: members,
                                       directoryURL: folder, folderKey: folder.path))
            }
            var group = ReviewGroup(photos: pair.map(\.photo), keeperID: pair[0].id)
            group.rejected = [pair[1].id]
            items += pair
            groups.append(group)
        }
        self.items = items
        self.groups = groups
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func facts(_ url: URL) -> VolumeFacts {
        VolumeFacts(isLocal: true, isReadOnly: false, mntRdOnly: false,
                    fileSystemType: "apfs", isRootFileSystem: false, path: url.path)
    }
    func probe(_ url: URL) -> VolumeProbeResult {
        let probe = probeVolume(at: url)
        return VolumeProbeResult(facts: facts(url), volumeKey: probe.volumeKey,
                                 displayName: "Fixture", volumeURL: probe.volumeURL,
                                 capability: classifyTrashLocation(facts(url)))
    }
    var grants: FolderLocationGrants {
        FolderLocationGrants(status: { _ in self.status }, access: { root in
            self.attempts += 1
            guard self.usable else { return nil }
            self.active += 1
            self.events.append("start")
            return FolderResolvedItem(url: self.wrongRoot ? self.root : root, stopAccessing: {
                self.events.append("stop")
                self.active -= 1
            })
        })
    }
    func observe(_ name: String, _ url: URL) {
        if folderGrantLocation(for: url) != nil {
            scoped = scoped && active > 0
            events.append(name)
        }
    }
    var port: FolderTrashPort {
        var port = FolderTrashPort.confirmedLocation(trash: { url in
            self.observe("trash", url)
            self.trashCalls.append(url)
            if self.trashCalls.count == self.failTrashAt { throw CocoaError(.fileWriteNoPermission) }
            let destination = trashRoot(at: url)!.appendingPathComponent(url.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(url, destination)
            return destination
        }, locationFacts: { url in
            // Real probes cannot read volume properties from a trashed original.
            FileManager.default.fileExists(atPath: url.path) ? self.facts(url) : VolumeFacts()
        })
        port.readMember = { url in
            self.observe("read", url)
            return try? FolderMember.read(at: url)
        }
        port.validateResult = { source, result in
            self.observe("validate", source)
            return validateTrashLocation(sourceURL: source, resultingURL: result)
        }
        port.verifyPrimary = { url, digest in
            self.observe("hash", url)
            return FolderTrashPort.verifyPrimaryHash(url, digest)
        }
        port.move = { source, destination in
            self.observe("move", source)
            self.moves.append((source, destination))
            if self.moves.count == self.failMoveAt { throw CocoaError(.fileWriteNoPermission) }
            try FolderTrashPort.moveWithoutOverwrite(source, destination)
        }
        return port
    }
    func store() -> FolderHistoryStore {
        FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                           intentURL: root.appendingPathComponent("intent.json"))
    }
    func committer(_ store: FolderHistoryStore) -> FolderCommitter {
        FolderCommitter(history: store, trashPort: port, grants: grants, volumeProbe: probe)
    }
    func session(_ store: FolderHistoryStore) throws -> FolderLibrarySession {
        let bookmarks = FolderBookmarkStore(url: root.appendingPathComponent("bookmarks.json"),
            makeAccess: { try FolderAccess(url: $0, startAccess: { _ in true }, stopAccess: { _ in }) },
            resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
        try FolderHistoryStore.atomicWrite(JSONEncoder().encode(folders.map {
            FolderBookmark(data: Data($0.path.utf8))
        }), bookmarks.url)
        return FolderLibrarySession(bookmarks: bookmarks, history: store, trashPort: port, grants: grants,
            volumeProbe: probe, scan: { roots in
                self.scans += 1
                self.scoped = self.scoped && self.active == 0
                    && roots.map(folderLocationComponents) == self.folders.map(folderLocationComponents)
                return FolderScanResult(items: self.items, groups: self.groups, exactGroupIDs: [],
                    crossFolderDuplicates: [], roots: roots.map { FolderScannedRoot(url: $0, volume: self.probe($0)) },
                    issues: [], primaryHashes: [:], uniqueMetadataWithheld: 0, uniqueMetadataIDs: [], knownCarryingIDs: [],
                    imageProvider: FolderImageProvider(items: self.items), accesses: [])
            }, metadata: { _ in [:] })
    }
}

@MainActor
func folderLocationGrantClassificationTests(_ check: (Bool, String) -> Void) {
    print("Location grant classification and platform isolation")
    do {
        let f = try LocationGrantFixture()
        defer { f.cleanup() }
        for status in [FolderLocationGrantStatus.notAsked, .granted, .declined] {
            check(classifyTrashLocation(f.facts(f.folders[0]), grantStatus: status)
                  == (status == .declined ? .scanOnly(.locationGrantNeeded) : .removalSupported),
                  "on-device capability follows grant status")
            check(classifyTrashLocation(f.facts(f.folders[2]), grantStatus: status) == .removalSupported,
                  "iCloud capability ignores every grant status")
            check(classifyVolume(f.facts(f.folders[0])) == .removalSupported,
                  "macOS volume classification remains unchanged")
        }
        check(folderGrantLocation(for: f.items[1].primary.url) == folderGrantLocation(for: f.storage)
              && folderGrantLocation(for: f.folders[2]) == nil,
              "public grant location returns only the normalized storage root")
        var unexpectedCalls = 0
        let hostile = FolderLocationGrants(status: { _ in
            unexpectedCalls += 1; return .declined
        }, access: { _ in unexpectedCalls += 1; return nil })
        let mac = FolderTrashPort(trash: { _ in nil })
        check(mac.capability(f.probe(f.folders[0]), at: f.folders[0], grants: hostile) == .removalSupported,
              "ordinary macOS port has no location grant concept")
        check(f.port.capability(f.probe(f.folders[2]), at: f.folders[2], grants: hostile) == .removalSupported,
              "iCloud port never consults a grant")
        let scanOnly = VolumeProbeResult(facts: f.facts(f.folders[0]), volumeKey: nil,
            displayName: nil, volumeURL: nil, capability: .scanOnly(.readOnly))
        check(f.port.capability(scanOnly, at: f.folders[0], grants: hostile) == .scanOnly(.readOnly),
              "scan-only capabilities never consult a grant")
        check(unexpectedCalls == 0, "non-grant capabilities never call either grant effect")
    } catch { check(false, "grant classification fixture: \(error)") }
}

@MainActor
func folderLocationGrantCommitTests(_ check: (Bool, String) -> Void) async {
    print("Location grant commit access, refusal and rollback")
    for mode in ["granted", "notAsked", "none", "missing", "declined", "wrong-root", "rollback"] {
        do {
            let f = try LocationGrantFixture()
            defer { f.cleanup() }
            f.status = mode == "declined" ? .declined : mode == "notAsked" ? .notAsked : .granted
            f.usable = mode != "missing"
            f.wrongRoot = mode == "wrong-root"
            if mode == "rollback" { f.failTrashAt = 2 }
            let store = f.store()
            var failures: [FolderRemovalFailure] = []
            var withdrawals: [FolderGroupWithdrawal] = []
            let committer = mode == "none"
                ? FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe) : f.committer(store)
            let count = try await committer.commit(groups: f.groups, items: f.items, primaryHashes: [:],
                callbacks: FolderCommitCallbacks(onGroupsWithdrawn: { withdrawals = $0 },
                                                 onRemovalFailed: { failures.append($0) }))
            let refused = ["none", "missing", "declined", "wrong-root"].contains(mode)
            check(count == (refused ? 1 : mode == "rollback" ? 2 : 3),
                  "mixed commit preserves independent iCloud removal: \(mode)")
            check(f.attempts == (["none", "declined"].contains(mode) ? 0 : 1) && f.active == 0,
                  "commit acquires each storage root once, including failed attempts: \(mode)")
            check(f.scoped && (f.events.isEmpty || f.events.last == "stop"),
                  "scope covers trash, result reads, validation and rollback and then stops: \(mode)")
            if refused {
                check(f.trashCalls == [f.items[5].primary.url]
                      && FileManager.default.fileExists(atPath: f.items[1].primary.url.path),
                      "missing grant never moves any member of the on-device item: \(mode)")
                if mode == "declined" {
                    check(withdrawals.count == 2 && withdrawals.allSatisfy {
                        $0.reason == .scanOnly(f.items[1].volumeKey, .locationGrantNeeded)
                    }, "declined grant withdraws scan-only groups with its reason")
                } else {
                    check(failures.count == 2 && failures.allSatisfy {
                        if case .locationGrantMissing(let root) = $0.reason {
                            return root == folderGrantLocation(for: f.storage)
                        }
                        return false
                    }, "unusable grants report locationGrantMissing per item")
                }
            }
            if mode == "rollback" {
                check(f.moves.count == 1 && f.moves[0].1 == f.items[1].primary.url
                      && FileManager.default.fileExists(atPath: f.items[1].primary.url.path),
                      "partial removal rolls back inside root scope")
            }
            check(try store.pendingIntent().isEmpty && store.records().count == count,
                  "grant refusal preserves existing intent and history semantics: \(mode)")
        } catch { check(false, "grant commit fixture (\(mode)): \(error)") }
    }
}

@MainActor
func folderLocationGrantHistoryTests(_ check: (Bool, String) -> Void) async {
    print("Location grant history, Put Back and deferred recovery")
    for mode in ["restore", "missing", "declined", "rollback", "reconcile", "restoring"] {
        do {
            let f = try LocationGrantFixture()
            defer { f.cleanup() }
            let store = f.store()
            _ = try await f.committer(store).commit(groups: [f.groups[0]], items: f.items, primaryHashes: [:])
            var record = try store.records()[0]
            let original = record.members[0].originalURL
            let trash = record.members[0].trashURL!
            f.events = []
            f.attempts = 0
            if ["missing", "declined", "reconcile", "restoring"].contains(mode) { f.usable = false }
            if mode == "declined" { f.status = .declined }
            if mode == "rollback" { f.failMoveAt = 2 }
            if mode == "reconcile" {
                try store.writeIntent([record])
                try FileManager.default.removeItem(at: store.historyURL)
                check(try store.reconcileIntent(port: f.port, grants: f.grants).isEmpty
                      && store.pendingIntent().map(\.id) == [record.id] && store.records().isEmpty,
                      "missing root grant defers removal intent without booking it lost")
                f.usable = true
                check(try store.reconcileIntent(port: f.port, grants: f.grants).first?.state == .removed
                      && store.pendingIntent().isEmpty,
                      "grant restoration resumes deferred intent with identity validation")
            } else if mode == "restoring" {
                record.state = .restoring
                try FolderHistoryStore.atomicWrite(JSONEncoder().encode([record]), store.historyURL)
                _ = try store.reconcileIntent(port: f.port, grants: f.grants)
                check(try store.records()[0].state == .restoring,
                      "missing grant leaves an interrupted Put Back pending")
                f.usable = true
                _ = try store.reconcileIntent(port: f.port, grants: f.grants)
                check(try store.records()[0].state == .removed,
                      "interrupted Put Back reconciles under restored grant")
            } else {
                let entries = try store.entries(port: f.port, grants: f.grants)
                check(entries[0].putBackAvailable == f.usable
                      && entries[0].putBackNeedsGrant == (f.usable ? nil : folderGrantLocation(for: original)),
                      "history lists grant need without reading inaccessible Trash: \(mode)")
                check(store.canPutBack(record, port: f.port, grants: f.grants) == f.usable && f.active == 0,
                      "canPutBack releases its root scope: \(mode)")
                let result = try store.putBack(record.id, port: f.port, grants: f.grants)
                switch result {
                case .restored:
                    check(mode == "restore" && f.moves.count == 2 && f.moves[0].0 == trash
                          && f.moves[0].1 == original && FileManager.default.fileExists(atPath: original.path),
                          "Put Back restores directly from the result URL inside root scope")
                case .locationGrantNeeded(let root):
                    check(!f.usable && root == folderGrantLocation(for: original) && f.moves.isEmpty
                          && f.events.isEmpty && FileManager.default.fileExists(atPath: trash.path),
                          "missing or declined grant refuses all Put Back reads and moves")
                case .failed:
                    check(mode == "rollback" && f.moves.count == 3 && f.moves[2].1 == trash,
                          "Put Back rollback retains root scope through the reverse move")
                default: check(false, "unexpected Put Back result: \(mode)")
                }
            }
            check(f.active == 0 && f.scoped && (f.events.isEmpty || f.events.last == "stop"),
                  "history, verification, hash, moves and reconciliation balance root scope: \(mode)")
        } catch { check(false, "grant history fixture (\(mode)): \(error)") }
    }
}

@MainActor
func folderLocationGrantSessionTests(_ check: (Bool, String) -> Void) async {
    print("Location grant preflight and capability refresh without scanning")
    do {
        let f = try LocationGrantFixture()
        defer { f.cleanup() }
        let store = f.store()
        let session = try f.session(store)
        session.loadFolders()
        session.startScan()
        for _ in 0..<10_000 {
            if !session.isScanning { break }
            await Task.yield()
        }
        check(session.hasScanned && f.scans == 1 && f.attempts == 0 && f.scoped,
              "scan only receives added folders and never acquires the root grant")
        session.presentRemovalReview()
        guard let review = session.removalReview else { check(false, "grant review presented"); return }
        f.usable = false
        check(session.locationsNeedingGrant(for: review) == [folderGrantLocation(for: f.storage)!]
              && f.attempts == 1 && f.active == 0,
              "preflight deduplicates missing roots across members and folders")
        f.usable = true
        check(session.locationsNeedingGrant(for: review).isEmpty && f.active == 0
              && f.events == ["start", "stop"],
              "preflight starts and immediately stops a usable scope")
        let cloudReview = FolderRemovalReview(
            summary: f.committer(store).preCommitSummary(groups: [f.groups[2]], items: f.items), groups: [f.groups[2]])
        let attempts = f.attempts
        check(session.locationsNeedingGrant(for: cloudReview).isEmpty && f.attempts == attempts,
              "iCloud preflight never consults access")
        f.status = .declined
        session.refreshLocationCapabilities()
        check(session.result?.roots[0].volume.capability == .scanOnly(.locationGrantNeeded)
              && session.result?.roots[2].volume.capability == .removalSupported
              && session.removalReview?.summary.eligibleItemIDs == [f.items[5].id]
              && session.removalReview?.summary.volumes[0].capability == .scanOnly(.locationGrantNeeded),
              "refresh updates roots and final review with declined grant reason")
        session.cancelRemovalReview()
        session.keepAll(group: f.groups[2].id)
        check(!session.canReviewRemoval, "declined roots cannot enter removal review")
        f.status = .granted
        session.refreshLocationCapabilities()
        check(session.canReviewRemoval && session.result?.roots[0].volume.capability == .removalSupported
              && f.scans == 1 && session.result?.items.count == f.items.count && f.active == 0,
              "grant change restores eligibility without rescanning or widening items")
        f.status = .declined
        check(!session.canReviewRemoval && session.result?.roots[0].volume.capability == .removalSupported,
              "per-member grant status gates review even before root capabilities refresh")
        f.status = .granted
        session.presentRemovalReview()
        if let refreshed = session.removalReview {
            let result = await session.commitReviewed(refreshed)
            check(result?.removedCount == 2, "session passes location grants into commit")
        } else { check(false, "refreshed grant review presented") }
        f.usable = false
        session.presentHistory()
        check(session.historyEntries.count == 2 && session.historyEntries.allSatisfy {
            !$0.putBackAvailable && $0.putBackNeedsGrant == folderGrantLocation(for: f.storage)
        }, "session history passes grants and exposes withdrawn access")
        if let entry = session.historyEntries.first {
            await session.putBack(entry)
            if case .putBack(.locationGrantNeeded(let root))? = session.operationReport?.first {
                check(root == folderGrantLocation(for: f.storage) && f.moves.isEmpty,
                      "session surfaces typed Put Back grant need")
            } else { check(false, "session Put Back grant report") }
        }
    } catch { check(false, "grant session fixture: \(error)") }
}
