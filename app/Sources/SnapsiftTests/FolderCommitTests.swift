import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore
import SnapsiftFolder

private enum FolderCommitTestError: Error { case fixture, refused }

@MainActor
private final class FolderCommitFixture {
    let root: URL
    let source: URL
    let trash: URL
    var items: [FolderItem]
    var groups: [ReviewGroup]
    var hashes: [String: String] = [:]
    var withdrawals: [FolderGroupWithdrawal] = []
    var failures: [FolderRemovalFailure] = []
    var committed: CommitResult?
    var protectedCount = 0
    var undeterminedCount = 0
    var trashCalls: [URL] = []
    var moveCalls: [(URL, URL)] = []
    var failTrashAt: Int?
    var failMoveAt: Set<Int> = []
    var invalidResult = false
    var unknownResult = false
    var writeCount = 0
    var failWriteAt: Set<Int> = []
    var failHistoryWrite = false
    var advances: [[FolderHistoryRecord]] = []
    var inspectBeforeTrash: (() throws -> Void)?
    var volumeOverride: ((URL) -> VolumeProbeResult)?
    lazy var store = FolderHistoryStore(
        historyURL: root.appendingPathComponent("folder/history.json"),
        intentURL: root.appendingPathComponent("folder/pending-removal.json"),
        write: { data, url in
            self.writeCount += 1
            if self.failWriteAt.contains(self.writeCount)
                || (self.failHistoryWrite && url.lastPathComponent == "history.json") {
                throw FolderCommitTestError.refused
            }
            try FolderHistoryStore.atomicWrite(data, url)
            if url.lastPathComponent == "pending-removal.json" {
                self.advances.append(try JSONDecoder().decode([FolderHistoryRecord].self, from: data))
            }
        }, volumeProbe: { self.volumeOverride?($0) ?? probeVolume(at: $0) })

    init(companions: [String] = [], candidates: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-commit-\(UUID())")
        source = root.appendingPathComponent("source")
        trash = root.appendingPathComponent("fake-trash")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        for name in ["a.jpg"] + (1...candidates).map({ "\(Character(UnicodeScalar(97 + $0)!)).jpg" }) {
            let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let dest = CGImageDestinationCreateWithURL(source.appendingPathComponent(name) as CFURL,
                                                            UTType.jpeg.identifier as CFString, 1, nil)
            else { throw FolderCommitTestError.fixture }
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            guard CGImageDestinationFinalize(dest) else { throw FolderCommitTestError.fixture }
        }
        for name in companions { try Data("companion".utf8).write(to: source.appendingPathComponent(name)) }
        for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                                   ofItemAtPath: url.path)
        }
        items = try FolderEnumerator.enumerate(root: source).items.map {
            $0.with(photo: $0.photo.with(documentEvalDegraded: false))
        }.sorted { $0.primary.url.path < $1.primary.url.path }
        guard items.count == candidates + 1 else { throw FolderCommitTestError.fixture }
        var group = ReviewGroup(photos: items.map(\.photo), keeperID: items[0].id)
        group.rejected = Set(items.dropFirst().map(\.id))
        groups = [group]
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    var candidate: FolderItem { items[1] }
    var port: FolderTrashPort {
        FolderTrashPort(trash: { url in
            try self.inspectBeforeTrash?()
            self.trashCalls.append(url)
            if self.failTrashAt == self.trashCalls.count { throw FolderCommitTestError.refused }
            if self.invalidResult { return self.trash.appendingPathComponent("missing") }
            let result = self.trash.appendingPathComponent(url.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(url, result)
            return self.unknownResult ? nil : result
        }, move: { from, to in
            self.moveCalls.append((from, to))
            if self.failMoveAt.contains(self.moveCalls.count) { throw FolderCommitTestError.refused }
            try FolderTrashPort.moveWithoutOverwrite(from, to)
        })
    }
    var committer: FolderCommitter {
        FolderCommitter(history: store, trashPort: port,
                        volumeProbe: { self.volumeOverride?($0) ?? probeVolume(at: $0) })
    }
    func run(isBusy: Bool = false) async throws -> Int {
        try await committer.commit(groups: groups, items: items, primaryHashes: hashes, isBusy: isBusy,
                                   callbacks: FolderCommitCallbacks(
                                    onGroupsWithdrawn: { self.withdrawals += $0 },
                                    onRemovalFailed: { self.failures.append($0) },
                                    shared: CommitCallbacks(
                                        onProtectedDropped: { self.protectedCount += $0 },
                                        onUndeterminedSkipped: { self.undeterminedCount += $0 },
                                        onGroupsChanged: { self.groups = $0 },
                                        onCommitted: { self.committed = $0 })))
    }
    func record(_ item: FolderItem? = nil, timestamp: String = "2026-10-10T00:00:00Z") -> FolderHistoryRecord {
        FolderHistoryRecord(item: item ?? candidate, timestamp: timestamp,
                            primarySHA256: "fixture-hash", reason: .userRejected)
    }
    func moveRecord(_ record: inout FolderHistoryRecord) throws {
        for i in record.members.indices {
            let result = trash.appendingPathComponent(record.members[i].originalURL.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(record.members[i].originalURL, result)
            record.members[i].trashURL = result
        }
        record.state = .removed
    }
}

@MainActor
func checkFolderCommitAndHistory() async {
    print("Folder commit/history through fake Trash ports")
    for mode in ["size", "mtime", "identity", "missing", "survivor", "companion", "unavailable", "scan-only", "hash", "survivor-hash"] {
        do {
            let f = try FolderCommitFixture(companions: mode == "companion" ? ["b.mov"] : [])
            defer { f.cleanup() }
            let target = mode == "survivor" ? f.items[0].primary : f.candidate.primary
            switch mode {
            case "size", "survivor":
                let handle = try FileHandle(forWritingTo: target.url)
                try handle.seekToEnd(); try handle.write(contentsOf: Data([1])); try handle.close()
            case "mtime":
                try FileManager.default.setAttributes([.modificationDate: target.modificationDate.addingTimeInterval(10)],
                                                       ofItemAtPath: target.url.path)
            case "identity":
                let replacement = f.source.appendingPathComponent("replacement")
                try FileManager.default.copyItem(at: target.url, to: replacement)
                try FileManager.default.removeItem(at: target.url)
                try FileManager.default.moveItem(at: replacement, to: target.url)
            case "missing": try FileManager.default.removeItem(at: target.url)
            case "companion": try FileManager.default.removeItem(at: f.candidate.members.first { $0.url.pathExtension == "mov" }!.url)
            case "unavailable":
                f.volumeOverride = { _ in VolumeProbeResult(facts: VolumeFacts(), volumeKey: nil, displayName: nil, volumeURL: nil) }
            case "scan-only":
                f.volumeOverride = { url in
                    let p = probeVolume(at: url)
                    return VolumeProbeResult(facts: VolumeFacts(isLocal: false, isReadOnly: false, mntRdOnly: false,
                                                               fileSystemType: "smbfs", isRootFileSystem: false),
                                             volumeKey: p.volumeKey, displayName: "NAS", volumeURL: p.volumeURL)
                }
            case "hash", "survivor-hash":
                f.groups[0].autoSeeded = [f.candidate.id]
                // Change content while retaining every captured file fact.
                for item in f.items { f.hashes[item.id] = await FolderOriginalHasher(items: f.items).sha256(itemIdentifier: item.id) }
                let changed = mode == "hash" ? f.candidate : f.items[0]
                let handle = try FileHandle(forWritingTo: changed.primary.url)
                try handle.write(contentsOf: Data([0])); try handle.close()
                try FileManager.default.setAttributes([.modificationDate: changed.primary.modificationDate],
                                                       ofItemAtPath: changed.primary.url.path)
                check(try FolderMember.read(at: changed.primary.url) == changed.primary,
                      "folder hash fixture: content changed with identical size, identity and mtime")
            default: break
            }
            check(try await f.run() == 0, "folder pre-gate: \(mode) withdraws the entire group")
            check(f.withdrawals.count == 1 && f.withdrawals[0].itemCount == 1
                  && f.trashCalls.isEmpty && f.protectedCount == 0 && f.undeterminedCount == 0,
                  "folder pre-gate: \(mode) has its own count/reason callback, no Photos/sweep callback or move")
            let expected: FolderWithdrawalReason
            switch mode {
            case "size", "survivor": expected = .sizeChanged(target.url)
            case "mtime": expected = .modificationDateChanged(target.url)
            case "identity": expected = .identityChanged(target.url)
            case "missing": expected = .memberMissing(target.url)
            case "companion": expected = .memberMissing(f.candidate.members.first { $0.url.pathExtension == "mov" }!.url)
            case "unavailable": expected = .volumeUnavailable(f.candidate.volumeKey)
            case "scan-only": expected = .scanOnly(f.candidate.volumeKey, .networkVolume)
            default: expected = .hashMismatch(mode == "hash" ? f.candidate.id : f.items[0].id)
            }
            check(f.withdrawals.first?.reason == expected, "folder pre-gate: \(mode) reports the specific live mismatch")
            check(try f.groups[0].rejected == [f.candidate.id] && (try f.store.records()).isEmpty,
                  "folder pre-gate: \(mode) retains group marks and creates no history")
        } catch { check(false, "folder pre-gate fixture \(mode): \(error)") }
    }

    do {
        let f = try FolderCommitFixture(candidates: 2)
        defer { f.cleanup() }
        let summary = f.committer.preCommitSummary(groups: f.groups, items: f.items)
        check(summary.itemCount == 2 && summary.totalBytes == f.items.dropFirst().reduce(0, { $0 + $1.photo.size })
              && summary.eligibleItemIDs == Set(f.items.dropFirst().map(\.id)), "folder summary: effective item count and bytes")
        check(summary.volumes.count == 1 && summary.volumes[0].itemCount == 2
              && summary.volumes[0].isStartupVolume && !summary.volumes[0].displayName.isEmpty,
              "folder summary: volume display name and startup-volume flag")
        f.volumeOverride = { url in
            let p = probeVolume(at: url)
            return VolumeProbeResult(facts: VolumeFacts(isLocal: true, isReadOnly: false, mntRdOnly: false,
                                                       fileSystemType: "exfat", isRootFileSystem: false),
                                     volumeKey: p.volumeKey, displayName: "External", volumeURL: p.volumeURL)
        }
        check(!f.committer.preCommitSummary(groups: f.groups, items: f.items).volumes[0].isStartupVolume,
              "folder summary: non-startup volume is explicit for the space warning")
        f.volumeOverride = { url in
            let p = probeVolume(at: url)
            return VolumeProbeResult(facts: VolumeFacts(isLocal: true, isReadOnly: true, mntRdOnly: true,
                                                       fileSystemType: "apfs", isRootFileSystem: false),
                                     volumeKey: p.volumeKey, displayName: "Locked", volumeURL: p.volumeURL)
        }
        let locked = f.committer.preCommitSummary(groups: f.groups, items: f.items)
        check(locked.eligibleItemIDs.isEmpty && locked.withdrawals.count == 1
              && locked.volumes[0].capability == .scanOnly(.readOnly), "folder summary: scan-only group ineligible with reason")
    } catch { check(false, "folder summary: \(error)") }

    do {
        let f = try FolderCommitFixture(candidates: 2)
        defer { f.cleanup() }
        try Data("new edit".utf8).write(to: f.source.appendingPathComponent("B.XMP"))
        check(try await f.run() == 1 && f.protectedCount == 1 && f.undeterminedCount == 0,
              "folder sweep: new sidecar protects its photo; every target has an editedNow value")
        check(f.groups[0].photos.first { $0.uuid == f.candidate.id }?.edited == true
              && !f.groups[0].rejected.contains(f.candidate.id)
              && FileManager.default.fileExists(atPath: f.candidate.primary.url.path),
              "folder sweep: newly protected photo remains and is unmarked")
    } catch { check(false, "folder sidecar sweep: \(error)") }

    do {
        let f = try FolderCommitFixture()
        defer { f.cleanup() }
        f.groups[0].photos[1] = f.groups[0].photos[1].with(isDocument: true)
        f.groups[0].includeProtected = true
        try Data("new edit".utf8).write(to: f.source.appendingPathComponent("b.xmp"))
        check(try await f.run() == 0 && f.withdrawals.first?.reason == .membersChanged(f.candidate.id)
              && f.trashCalls.isEmpty && f.protectedCount == 0,
              "folder pre-gate: new companion on a force-included protected frame withdraws for fresh scan facts")
    } catch { check(false, "folder force-included new sidecar: \(error)") }

    do {
        let f = try FolderCommitFixture()
        defer { f.cleanup() }
        let photosLog = f.root.appendingPathComponent("photos/deletions.jsonl")
        let photosIntent = f.root.appendingPathComponent("photos/pending-delete.json")
        let snapshot = f.root.appendingPathComponent("photos/last-scan.json")
        let photos = DeletionSession(timestamp: "photos", records: [DeletionRecord(
            timestamp: "photos", assetIdentifier: "photos-id", filename: "photo", sizeBytes: 1,
            keeperIdentifier: "keeper", keeperFilename: "keeper", reason: .userRejected)])
        check(DeletionAuditLog.append(photos, to: photosLog) && DeletionAuditLog.writeIntent(photos, to: photosIntent),
              "folder isolation fixture: injected Photos stores written")
        try Data("Photos snapshot sentinel".utf8).write(to: snapshot)
        let before = try [photosLog, photosIntent, snapshot].map { try Data(contentsOf: $0) }
        f.inspectBeforeTrash = {
            check(try f.store.pendingIntent().count == 1, "folder journal: intent exists before the first move")
        }
        check(try await f.run() == 1 && f.committed?.deletedIDs == [f.candidate.id] && f.committed?.auditFailed == false,
              "folder commit: single success reports only the removed ID")
        let records = try f.store.records()
        check(records.count == 1 && records[0].state == .removed && records[0].members[0].trashURL != nil
              && records[0].members[0].originalURL == f.candidate.primary.url
              && records[0].primarySHA256.count == 64 && records[0].reason == .userRejected,
              "folder history: actual Trash URL, original path, SHA-256, size, volume, time and reason")
        check(try f.store.pendingIntent().isEmpty && f.advances.contains { $0[0].members[0].trashURL != nil },
              "folder journal: advanced with resulting URL and cleared after history")
        check(try [photosLog, photosIntent, snapshot].map { try Data(contentsOf: $0) } == before,
              "folder isolation: injected Photos log/intent/snapshot are byte-for-byte untouched")
        check(FolderHistoryStore.directory == FolderBookmarkStore.defaultURL.deletingLastPathComponent()
              && FolderHistoryStore.directory != DeletionAuditLog.directory,
              "folder isolation: default history/intent area is separate from Photos")
        let entries = try f.store.entries()
        check(entries[0].putBackAvailable, "folder Put Back: existing same-volume Trash item is available")
        if case .restored = try f.store.putBack(entries[0].id, port: f.port) {
            check(true, "folder Put Back: success")
        } else { check(false, "folder Put Back: expected success") }
        check(try FileManager.default.fileExists(atPath: f.candidate.primary.url.path)
              && (try f.store.entries())[0].record.state == .restored && !(try f.store.entries())[0].putBackAvailable,
              "folder Put Back: original restored and history marked restored")
    } catch { check(false, "folder success/isolation/Put Back: \(error)") }

    for mode in ["second-member", "trash-throw", "validator", "rollback-failure", "initial-write", "advance-write", "history-write", "unknown-result"] {
        do {
            let f = try FolderCommitFixture(companions: ["b.mov"])
            defer { f.cleanup() }
            switch mode {
            case "second-member": f.failTrashAt = 2
            case "trash-throw": f.failTrashAt = 1
            case "validator": f.invalidResult = true
            case "rollback-failure": f.failTrashAt = 2; f.failMoveAt = [1]
            case "initial-write": f.failWriteAt = [1]
            case "advance-write": f.failWriteAt = [2]
            case "history-write": f.failHistoryWrite = true
            case "unknown-result": f.unknownResult = true
            default: break
            }
            do {
                let count = try await f.run()
                check(count == (mode == "history-write" ? 1 : 0), "folder failure: \(mode) reports actual item count")
            } catch CommitError.journalWriteFailed {
                check(mode == "initial-write", "folder journal: initial write failure blocks the commit")
            }
            if mode == "initial-write" {
                check(f.trashCalls.isEmpty && f.committed == nil, "folder journal: write failure blocks every move")
            } else if mode == "history-write" {
                check(try f.committed?.auditFailed == true && (try f.store.pendingIntent()).first?.state == .removed,
                      "folder history: append failure retains known completed intent for recovery")
                f.failHistoryWrite = false
                check(try f.store.reconcileIntent().count == 1 && f.store.entries()[0].putBackAvailable,
                      "folder history: failed append reconciles with Put Back")
            } else {
                check(try f.failures.count == 1 && f.committed?.deletedIDs.isEmpty == true
                      && (try f.store.records()).isEmpty && f.groups[0].rejected == [f.candidate.id],
                      "folder failure: \(mode) reported, not audited as removed, stays in group")
                if ["second-member", "trash-throw", "validator", "advance-write"].contains(mode) {
                    check(f.candidate.members.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
                          "folder failure: \(mode) leaves all originals in place; no permanent fallback")
                }
                if mode == "second-member" {
                    check(f.moveCalls.count == 1 && f.moveCalls[0].1 == f.candidate.primary.url
                          && f.advances.contains { $0[0].members[0].trashURL != nil },
                          "folder grouping: second-member failure puts primary back and records member progress")
                }
                if mode == "rollback-failure" || mode == "unknown-result" {
                    if case .rollbackFailed = f.failures[0].reason { check(true, "folder failure: rollback/unknown location is distinct") }
                    else { check(false, "folder failure: expected distinct rollback failure") }
                    check((try f.store.pendingIntent()).first?.state == .rollbackFailed,
                          "folder failure: journal retains exactly the known and unknown member locations")
                }
            }
        } catch { check(false, "folder failure fixture \(mode): \(error)") }
    }

    do {
        let f = try FolderCommitFixture(candidates: 2)
        defer { f.cleanup() }
        f.failTrashAt = 2
        check(try await f.run() == 1 && f.committed?.deletedIDs == [f.candidate.id]
              && (try f.store.records()).map(\.itemID) == [f.candidate.id],
              "folder partial success: only successfully removed items are committed and audited")
        check(f.groups[0].rejected.contains(f.items[2].id)
              && FileManager.default.fileExists(atPath: f.items[2].primary.url.path)
              && f.advances.contains { $0[0].state == .removed && $0[1].state == .pending },
              "folder partial success: failed item remains; journal advanced per item before next move")
    } catch { check(false, "folder partial success: \(error)") }

    do {
        let f = try FolderCommitFixture(companions: ["b.mov", "b.XMP", "b.aae"])
        defer { f.cleanup() }
        f.groups[0].includeProtected = true
        let count = try await f.run()
        check(count == 1 && f.trashCalls.first == f.candidate.primary.url && f.trashCalls.count == 4,
              "folder grouping: force-included image, motion and editing sidecars all move primary first")
        guard let record = try f.store.records().first else { throw FolderCommitTestError.fixture }
        check(record.reason == .forceIncludedProtectedEdited && record.members.count == 4,
              "folder history: force-included sidecar reason and every member recorded")
        if case .restored = try f.store.putBack(record.id, port: f.port) {
            check(f.candidate.members.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) },
                  "folder Put Back: grouped photo, movie and both sidecars restored together")
        } else { check(false, "folder Put Back: expected grouped success") }
    } catch { check(false, "folder grouped sidecars: \(error)") }

    await checkFolderReconciliation()
    await checkFolderPutBackFailures()
    await checkPartialCommitPort()
    await checkFolderHistoryRecovery()
    await checkFolderUnsupportedRename()
}

@MainActor
private func checkFolderUnsupportedRename() async {
    let unsupported: (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32 = { _, _, _ in
        errno = ENOTSUP
        return -1
    }
    for unsupportedError in [ENOTSUP, EINVAL] {
        do {
            let f = try FolderCommitFixture(companions: ["b.mov"])
            defer { f.cleanup() }
            _ = try await f.run()
            let record = try f.store.records()[0]
            let bytes = try record.members.map { try Data(contentsOf: $0.trashURL!) }
            var exclusiveCalls = 0
            var renameCalls = 0
            let port = FolderTrashPort(trash: f.port.trash, move: { from, to in
                try FolderTrashPort.moveWithoutOverwrite(from, to, exclusiveRename: { _, _, flags in
                    exclusiveCalls += 1
                    check(flags == UInt32(RENAME_EXCL), "folder fallback: exclusive rename remains primary")
                    errno = unsupportedError
                    return -1
                }, rename: { from, to in
                    renameCalls += 1
                    return Darwin.rename(from, to)
                })
            })
            if case .restored = try f.store.putBack(record.id, port: port) {
                check(true, "folder fallback: unsupported errno \(unsupportedError) restores grouped members")
            } else { check(false, "folder fallback: unsupported errno \(unsupportedError) must restore") }
            check(try record.members.enumerated().allSatisfy { index, member in
                let live = try FolderMember.read(at: member.originalURL)
                let restoredBytes = try Data(contentsOf: member.originalURL)
                return live.fileID == member.fileID && live.size == member.size
                    && live.modificationDate == member.modificationDate
                    && restoredBytes == bytes[index]
                    && !FileManager.default.fileExists(atPath: member.trashURL!.path)
            }, "folder fallback: restored bytes and file identities are unchanged")
            check(try exclusiveCalls == 2 && renameCalls == 2 && f.store.records()[0].state == .restored,
                  "folder fallback: each unsupported exclusive move falls back once and records restoration")
        } catch { check(false, "folder unsupported rename \(unsupportedError): \(error)") }
    }

    do {
        let f = try FolderCommitFixture()
        defer { f.cleanup() }
        _ = try await f.run()
        let record = try f.store.records()[0]
        let member = record.members[0]
        let sourceBytes = try Data(contentsOf: member.trashURL!)
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: member.originalURL)
        var renameCalls = 0
        let port = FolderTrashPort(trash: f.port.trash, move: { from, to in
            try FolderTrashPort.moveWithoutOverwrite(from, to, exclusiveRename: unsupported, rename: { from, to in
                renameCalls += 1
                return Darwin.rename(from, to)
            })
        })
        if case .conflict(let urls) = try f.store.putBack(record.id, port: port) {
            check(urls == [member.originalURL], "folder fallback: Put Back reports the existing destination conflict")
        } else { check(false, "folder fallback: existing destination must report a conflict") }
        // Bypass history preflight to exercise O_EXCL itself.
        do {
            try port.move(member.trashURL!, member.originalURL)
            check(false, "folder fallback: placeholder must refuse an existing destination")
        } catch {
            check((error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(EEXIST),
                  "folder fallback: exclusive placeholder reports EEXIST")
        }
        check(try renameCalls == 0 && Data(contentsOf: member.trashURL!) == sourceBytes
              && Data(contentsOf: member.originalURL) == sentinel,
              "folder fallback: conflict leaves both files intact without calling rename")
    } catch { check(false, "folder fallback conflict fixture: \(error)") }

    for mode in ["failure", "foreign-empty", "written", "foreign-link"] {
        do {
            let f = try FolderCommitFixture()
            defer { f.cleanup() }
            _ = try await f.run()
            let record = try f.store.records()[0]
            let member = record.members[0]
            let sourceBytes = try Data(contentsOf: member.trashURL!)
            let foreign = f.root.appendingPathComponent("foreign")
            let sentinel = Data("foreign contents".utf8)
            if mode == "foreign-link" {
                try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: member.trashURL!)
            } else { try Data().write(to: foreign) }
            var foreignInfo = stat()
            guard foreign.path.withCString({ lstat($0, &foreignInfo) }) == 0 else {
                throw FolderCommitTestError.fixture
            }
            var sawPlaceholder = false
            var changedDestination = false
            let port = FolderTrashPort(trash: f.port.trash, move: { from, to in
                try FolderTrashPort.moveWithoutOverwrite(from, to, exclusiveRename: unsupported, rename: { _, to in
                    var info = stat()
                    sawPlaceholder = lstat(to, &info) == 0
                        && (info.st_mode & S_IFMT) == S_IFREG && info.st_size == 0
                    if mode == "foreign-empty" || mode == "foreign-link" {
                        changedDestination = foreign.path.withCString { Darwin.rename($0, to) } == 0
                    } else if mode == "written" {
                        changedDestination = (try? sentinel.write(to: member.originalURL)) != nil
                    }
                    errno = EIO
                    return -1
                })
            })
            if case .failed = try f.store.putBack(record.id, port: port) {
                check(sawPlaceholder, "folder fallback: \(mode) rename failure follows creation of an empty regular placeholder")
            } else { check(false, "folder fallback: \(mode) rename failure must be reported") }
            check(try Data(contentsOf: member.trashURL!) == sourceBytes && f.store.records()[0].state == .removed,
                  "folder fallback: \(mode) rename failure preserves the Trash item and removal history")
            var destinationInfo = stat()
            let exists = member.originalURL.path.withCString { lstat($0, &destinationInfo) } == 0
            if mode == "failure" {
                check(!exists, "folder fallback: failed rename cleans up its unchanged placeholder")
            } else if mode == "written" {
                check(changedDestination && (try? Data(contentsOf: member.originalURL)) == sentinel,
                      "folder fallback: cleanup preserves a placeholder whose contents changed")
            } else {
                check(changedDestination && exists && destinationInfo.st_dev == foreignInfo.st_dev
                      && destinationInfo.st_ino == foreignInfo.st_ino,
                      "folder fallback: cleanup preserves the \(mode) destination with a different identity")
            }
        } catch { check(false, "folder fallback \(mode) fixture: \(error)") }
    }

    do {
        let f = try FolderCommitFixture(companions: ["b.mov"])
        defer { f.cleanup() }
        _ = try await f.run()
        let record = try f.store.records()[0]
        var renameCalls = 0
        let port = FolderTrashPort(trash: f.port.trash, move: { from, to in
            try FolderTrashPort.moveWithoutOverwrite(from, to, exclusiveRename: unsupported, rename: { from, to in
                renameCalls += 1
                if renameCalls == 2 { errno = EIO; return -1 }
                return Darwin.rename(from, to)
            })
        })
        if case .failed = try f.store.putBack(record.id, port: port) {
            check(try renameCalls == 3 && record.members.allSatisfy {
                FileManager.default.fileExists(atPath: $0.trashURL!.path)
                    && !FileManager.default.fileExists(atPath: $0.originalURL.path)
            } && f.store.canPutBack(f.store.records()[0]),
                  "folder fallback: partial Put Back rolls earlier members back through the same primitive")
        } else { check(false, "folder fallback: partial Put Back must fail after rollback") }
    } catch { check(false, "folder fallback partial Put Back: \(error)") }

    do {
        let f = try FolderCommitFixture(companions: ["b.mov"])
        defer { f.cleanup() }
        f.failTrashAt = 2
        var restoreCalls = 0
        let port = FolderTrashPort(trash: f.port.trash, move: { from, to in
            restoreCalls += 1
            try FolderTrashPort.moveWithoutOverwrite(from, to, exclusiveRename: unsupported)
        })
        let committer = FolderCommitter(history: f.store, trashPort: port)
        check(try await committer.commit(groups: f.groups, items: f.items, primaryHashes: [:]) == 0,
              "folder fallback: partial removal reports no committed grouped item")
        check(try restoreCalls == 1 && f.candidate.members.allSatisfy {
            (try? FolderMember.read(at: $0.url))?.fileID == $0.fileID
        } && FileManager.default.contentsOfDirectory(atPath: f.trash.path).isEmpty,
              "folder fallback: FolderCommitter restores earlier members with unchanged identities")
    } catch { check(false, "folder fallback partial removal: \(error)") }

    do {
        let f = try FolderCommitFixture()
        defer { f.cleanup() }
        let destination = f.trash.appendingPathComponent("refused")
        var renameCalls = 0
        do {
            try FolderTrashPort.moveWithoutOverwrite(f.candidate.primary.url, destination,
                                                     exclusiveRename: { _, _, _ in errno = EACCES; return -1 },
                                                     rename: { _, _ in renameCalls += 1; return 0 })
            check(false, "folder fallback: supported rename errors must be reported")
        } catch {
            check((error as NSError).code == Int(EACCES) && renameCalls == 0
                  && FileManager.default.fileExists(atPath: f.candidate.primary.url.path)
                  && !FileManager.default.fileExists(atPath: destination.path),
                  "folder fallback: errors other than ENOTSUP or EINVAL never create a placeholder")
        }
    } catch { check(false, "folder fallback errno gate: \(error)") }
}

@MainActor
private func checkFolderReconciliation() async {
    for mode in ["known", "originals", "unknown", "unknown-parent", "partial", "missing-trash", "unmounted"] {
        do {
            let f = try FolderCommitFixture(companions: mode == "partial" ? ["b.mov"] : [])
            defer { f.cleanup() }
            var record = f.record()
            switch mode {
            case "known", "missing-trash", "unmounted": try f.moveRecord(&record)
            case "unknown", "unknown-parent":
                try FolderTrashPort.moveWithoutOverwrite(record.members[0].originalURL,
                                                        f.trash.appendingPathComponent("unknown"))
            case "partial":
                let result = f.trash.appendingPathComponent("b.jpg")
                try FolderTrashPort.moveWithoutOverwrite(record.members[0].originalURL, result)
                record.members[0].trashURL = result
            default: break
            }
            if mode == "unknown-parent" { try FileManager.default.removeItem(at: f.source) }
            if mode == "missing-trash" { try FileManager.default.removeItem(at: record.members[0].trashURL!) }
            if mode == "unmounted" {
                f.volumeOverride = { _ in VolumeProbeResult(facts: VolumeFacts(), volumeKey: nil, displayName: nil, volumeURL: nil) }
            }
            try f.store.writeIntent([record])
            let booked = try f.store.reconcileIntent()
            switch mode {
            case "originals":
                check(try booked.isEmpty && (try f.store.records()).isEmpty && (try f.store.pendingIntent()).isEmpty,
                      "folder recovery: unchanged originals drop intent without inventing removal")
            case "unmounted":
                check(try booked.isEmpty && (try f.store.pendingIntent()).count == 1,
                      "folder recovery: detached known volume defers without losing recorded locations")
            default:
                check(try booked.count == 1 && (try f.store.pendingIntent()).isEmpty,
                      "folder recovery: \(mode) books once and clears after history append")
                guard let entry = try f.store.entries().first else { throw FolderCommitTestError.fixture }
                check(entry.putBackAvailable == (mode == "known"), "folder recovery: \(mode) Put Back availability")
                check(entry.record.state == (mode == "known" ? .removed : mode == "partial" ? .rollbackFailed
                                              : mode == "missing-trash" ? .trashMissing : .locationUnknown),
                      "folder recovery: \(mode) flags known/unknown/partial state honestly")
                try f.store.writeIntent([record])
                check(try f.store.reconcileIntent().isEmpty && f.store.records().count == 1,
                      "folder recovery: append-before-clear crash is idempotent by attempt ID")
            }
        } catch { check(false, "folder recovery fixture \(mode): \(error)") }
    }
}

@MainActor
private func checkFolderPutBackFailures() async {
    for mode in ["conflict", "dangling-link", "partial", "rollback-failure", "gone", "unmounted", "parent-missing", "replacement"] {
        do {
            let f = try FolderCommitFixture(companions: ["b.mov"])
            defer { f.cleanup() }
            _ = try await f.run()
            let record = try f.store.records()[0]
            switch mode {
            case "conflict": try Data("existing".utf8).write(to: record.members[1].originalURL)
            case "dangling-link":
                try FileManager.default.createSymbolicLink(at: record.members[1].originalURL,
                                                          withDestinationURL: f.root.appendingPathComponent("missing"))
            case "partial": f.failMoveAt = [2]
            case "rollback-failure": f.failMoveAt = [2, 3]
            case "gone": try FileManager.default.removeItem(at: record.members[1].trashURL!)
            case "unmounted":
                f.volumeOverride = { _ in VolumeProbeResult(facts: VolumeFacts(), volumeKey: nil, displayName: nil, volumeURL: nil) }
            case "parent-missing": try FileManager.default.removeItem(at: f.source)
            case "replacement":
                let replacement = f.root.appendingPathComponent("replacement")
                try FileManager.default.copyItem(at: record.members[0].trashURL!, to: replacement)
                try FileManager.default.removeItem(at: record.members[0].trashURL!)
                try FileManager.default.moveItem(at: replacement, to: record.members[0].trashURL!)
            default: break
            }
            let result = try f.store.putBack(record.id, port: f.port)
            switch result {
            case .conflict(let urls):
                check(["conflict", "dangling-link"].contains(mode) && urls.count == 1 && f.moveCalls.isEmpty,
                      "folder Put Back: \(mode) conflicts before any member moves")
            case .failed:
                check(try mode == "partial" && f.moveCalls.count == 3
                      && record.members.allSatisfy { FileManager.default.fileExists(atPath: $0.trashURL!.path) }
                      && f.store.canPutBack(try f.store.records()[0]),
                      "folder Put Back: partial failure rolls restored primary back to recorded Trash path")
            case .rollbackFailed(let urls, _):
                check(try mode == "rollback-failure" && urls == [record.members[0].originalURL]
                      && (try f.store.records())[0].members[0].restored,
                      "folder Put Back: rollback failure records which member remains restored")
            case .unavailable:
                check(try ["gone", "unmounted", "replacement"].contains(mode) && f.moveCalls.isEmpty
                      && !(try f.store.entries())[0].putBackAvailable,
                      "folder Put Back: \(mode) unavailable, no move")
            case .parentMissing:
                check(mode == "parent-missing" && f.moveCalls.isEmpty
                      && !FileManager.default.fileExists(atPath: f.source.path),
                      "folder Put Back: missing parents are reported without recreating user directories")
            default: check(false, "folder Put Back: unexpected \(mode) outcome")
            }
        } catch { check(false, "folder Put Back fixture \(mode): \(error)") }
    }
}

@MainActor
private func checkPartialCommitPort() async {
    do {
        var group = ReviewGroup(photos: [ph(1, 0), ph(2, 1), ph(3, 2)], keeperID: "U1")
        group.rejected = ["U2", "U3"]
        let f = CommitFixture([group])
        check(f.ports.deleteReporting == nil, "Core default: existing source has no partial-success port")
        check(try await f.run() == 2 && f.result?.deletedIDs == ["U2", "U3"]
              && f.audits[0].records.map(\.assetIdentifier) == ["U2", "U3"],
              "Core default: all-or-throw performer still audits and reports every requested item")
        let partial = CommitFixture([group])
        var ports = partial.ports
        ports.deleteReporting = { targets in
            check(targets.map(\.id) == ["U2", "U3"], "Core reporting: IDs paired with opaque source items")
            return ["U2", "unrequested"]
        }
        check(try await partial.orchestrator.commit(groups: partial.groups, ports: ports,
                                                    callbacks: partial.callbacks) == 1,
              "Core reporting: partial count and unrequested-ID filtering")
        check(partial.result?.deletedIDs == ["U2"] && partial.audits[0].records.map(\.assetIdentifier) == ["U2"]
              && !partial.events.contains("delete:U2,U3") && partial.intent == nil,
              "Core reporting: failed IDs omitted from audit/callback; journal still sequenced")
    } catch { check(false, "Core reporting port: \(error)") }
}

@MainActor
private func checkFolderHistoryRecovery() async {
    do {
        let f = try FolderCommitFixture(candidates: 2)
        defer { f.cleanup() }
        var older = f.record(timestamp: "2000-01-01T00:00:00Z")
        var newer = f.record(f.items[2], timestamp: "2026-10-10T00:00:00Z")
        try f.moveRecord(&older)
        try f.moveRecord(&newer)
        try f.store.append([older, newer])
        check(try f.store.entries().map(\.id) == [newer.id, older.id], "folder history: newest first")
        check(f.store.canPutBack(older), "folder history: no fixed retention; old entry still recoverable while Trash exists")
        // Directly verify the default move's race-safe no-overwrite contract.
        let from = f.root.appendingPathComponent("from"), to = f.root.appendingPathComponent("to")
        try Data("source".utf8).write(to: from)
        try Data("destination".utf8).write(to: to)
        do {
            try FolderTrashPort.moveWithoutOverwrite(from, to)
            check(false, "folder move: existing destination must refuse")
        } catch {
            check(try Data(contentsOf: from) == Data("source".utf8)
                  && Data(contentsOf: to) == Data("destination".utf8),
                  "folder move: exclusive rename leaves both existing files untouched")
        }
    } catch { check(false, "folder history ordering/exclusive move: \(error)") }
    for restoredCount in 0...2 {
        do {
            let f = try FolderCommitFixture(companions: ["b.mov"])
            defer { f.cleanup() }
            var record = f.record()
            try f.moveRecord(&record)
            record.state = .restoring
            try f.store.append([record])
            // Simulate a process death before the per-member history advance.
            for member in record.members.prefix(restoredCount) {
                try FolderTrashPort.moveWithoutOverwrite(member.trashURL!, member.originalURL)
            }
            _ = try f.store.reconcileIntent()
            let recovered = try f.store.records()[0]
            check(recovered.state == (restoredCount == 0 ? .removed : restoredCount == 2 ? .restored : .rollbackFailed),
                  "folder Put Back recovery: \(restoredCount) restored members classified from live facts")
            check(recovered.members.filter(\.restored).count == restoredCount,
                  "folder Put Back recovery: actual original/Trash member locations recorded")
        } catch { check(false, "folder Put Back recovery fixture: \(error)") }
    }
    do {
        let f = try FolderCommitFixture()
        defer { f.cleanup() }
        for item in f.items { f.hashes[item.id] = await FolderOriginalHasher(items: f.items).sha256(itemIdentifier: item.id) }
        f.groups[0].autoSeeded = [f.candidate.id]
        check(try await f.run() == 1 && f.store.records()[0].reason == .exactDuplicate,
              "folder exact commit: full primary re-match succeeds and history attributes the pre-mark")
    } catch { check(false, "folder exact commit: \(error)") }
}
