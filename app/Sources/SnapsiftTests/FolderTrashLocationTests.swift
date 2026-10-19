import Foundation
import SnapsiftCore
@testable import SnapsiftFolder

private func trashLocationFacts(_ path: String?, ubiquitous: Bool? = nil,
                                local: Bool? = true, readOnly: Bool? = false,
                                mountedReadOnly: Bool? = false,
                                fileSystem: String? = "apfs", root: Bool? = false) -> VolumeFacts {
    VolumeFacts(isLocal: local, isReadOnly: readOnly, mntRdOnly: mountedReadOnly,
                fileSystemType: fileSystem, isRootFileSystem: root,
                path: path, isUbiquitousItem: ubiquitous)
}

func folderTrashLocationTests(_ check: (Bool, String) -> Void) {
    print("iOS per-location Trash classification and result validation")
    let device = "/var/mobile/Containers/Shared/AppGroup/fixture/File Provider Storage"
    let simulator = "/Users/fixture/Library/Developer/CoreSimulator/Devices/device/data" +
        "/Containers/Shared/AppGroup/fixture/File Provider Storage"
    for storage in [device, simulator] {
        for prefix in ["", "/private"] {
            for suffix in ["", "/picked", "/picked/deeper/photo.jpg"] {
                let path = prefix + storage + suffix
                check(classifyTrashLocation(trashLocationFacts(path)) == .removalSupported,
                      "Trash location supports picked storage root/folder/member: \(path)")
            }
        }
    }
    let unconfirmed = [
        "/var/mobile/Containers/Data/Application/fixture/Documents",
        "/var/mobile/Containers/Data/Application/fixture/tmp/photo.jpg",
        "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/picked",
        device + "-other/picked",
        device.replacingOccurrences(of: "/fixture/", with: "/fixture/extra/") + "/picked",
        device + "/../../elsewhere",
        "/Volumes/External/picked",
        "Containers/Shared/AppGroup/fixture/File Provider Storage/picked",
    ]
    for path in unconfirmed {
        check(classifyTrashLocation(trashLocationFacts(path)) == .scanOnly(.systemTrashUnconfirmed),
              "Trash location fails closed for unconfirmed path: \(path)")
    }
    check(classifyTrashLocation(trashLocationFacts(nil)) == .scanOnly(.systemTrashUnconfirmed),
          "Trash location requires a captured path")
    check(classifyTrashLocation(trashLocationFacts(device + "/picked", ubiquitous: true)) == .scanOnly(.systemTrashUnconfirmed),
          "Trash location refuses ubiquitous items even in a matching storage path")
    check(classifyTrashLocation(trashLocationFacts(device, ubiquitous: false)) == .removalSupported,
          "Trash location accepts an explicitly non-ubiquitous storage root")
    let rejected: [(String, VolumeFacts, VolumeCapabilityReason)] = [
        ("non-local", trashLocationFacts(device, local: false), .networkVolume),
        ("network filesystem", trashLocationFacts(device, fileSystem: "smbfs"), .networkVolume),
        ("read-only", trashLocationFacts(device, readOnly: true), .readOnly),
        ("mounted read-only", trashLocationFacts(device, mountedReadOnly: true), .readOnly),
        ("unsupported filesystem", trashLocationFacts(device, fileSystem: "unknown"), .unsupportedFilesystemType),
        ("nil local", trashLocationFacts(device, local: nil), .signalsUnavailable),
        ("nil read-only", trashLocationFacts(device, readOnly: nil), .signalsUnavailable),
        ("nil mounted read-only", trashLocationFacts(device, mountedReadOnly: nil), .signalsUnavailable),
        ("nil filesystem", trashLocationFacts(device, fileSystem: nil), .signalsUnavailable),
        ("nil root", trashLocationFacts(device, root: nil), .signalsUnavailable),
        ("all nil", VolumeFacts(), .signalsUnavailable),
    ]
    for (name, facts, reason) in rejected {
        check(classifyTrashLocation(facts) == .scanOnly(reason), "Trash location preserves volume reason: \(name)")
    }
    let source = URL(fileURLWithPath: device + "/picked/photo.jpg")
    let result = URL(fileURLWithPath: "/private" + device + "/.Trash/photo.jpg")
    check(validateTrashLocation(sourceURL: source, resultingURL: result),
          "Trash result accepts the same storage root across /private aliases")
    for path in [device + "/picked/photo.jpg", device + "/.Trash-other/photo.jpg", device + "/.Trash",
                 device + "/.Trash/../elsewhere/photo.jpg",
                 device.replacingOccurrences(of: "/fixture/", with: "/other/") + "/.Trash/photo.jpg"] {
        check(!validateTrashLocation(sourceURL: source, resultingURL: URL(fileURLWithPath: path)),
              "Trash result rejects a path outside this storage root's .Trash: \(path)")
    }
    check(!validateTrashLocation(sourceURL: source, resultingURL: nil), "Trash location rejects a missing result URL")
}

@MainActor
private final class TrashLocationFixture {
    let root: URL
    let storage: URL
    let confirmed: URL
    let unconfirmed: URL
    let trash: URL
    let items: [FolderItem]
    let groups: [ReviewGroup]
    var trashCalls: [URL] = []
    var moveCalls: [URL] = []
    var outsideResult = false
    var unrelatedResult: URL?

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-trash-location-\(UUID())")
        storage = root.appendingPathComponent("Containers/Shared/AppGroup/fixture/File Provider Storage")
        confirmed = storage.appendingPathComponent("picked")
        unconfirmed = root.appendingPathComponent("Containers/Data/Application/fixture/Documents")
        trash = storage.appendingPathComponent(".Trash")
        for url in [confirmed, unconfirmed, trash] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var items: [FolderItem] = []
        var groups: [ReviewGroup] = []
        for (index, folder) in [confirmed, unconfirmed].enumerated() {
            var pair: [FolderItem] = []
            for name in ["keeper", "candidate"] {
                let url = folder.appendingPathComponent("\(index)-\(name).jpg")
                try Data("fixture \(index)-\(name)".utf8).write(to: url)
                let member = try FolderMember.read(at: url)
                let photo = Photo(uuid: url.path, filename: url.lastPathComponent, takenAt: Double(index),
                                  width: 16, height: 16, size: member.size, uti: "public.jpeg")
                pair.append(FolderItem(photo: photo, primary: member, members: [member],
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
    func probe(_ url: URL) -> VolumeProbeResult {
        let p = probeVolume(at: url)
        let facts = trashLocationFacts(url.path)
        return VolumeProbeResult(facts: facts, volumeKey: p.volumeKey, displayName: "Shared iOS volume",
                                 volumeURL: p.volumeURL, capability: classifyTrashLocation(facts))
    }
    func store() -> FolderHistoryStore {
        FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                           intentURL: root.appendingPathComponent("intent.json"))
    }
    var port: FolderTrashPort {
        var port = FolderTrashPort.confirmedLocation(trash: { url in
            self.trashCalls.append(url)
            if let unrelated = self.unrelatedResult { return unrelated }
            let destination = (self.outsideResult ? self.root : self.trash).appendingPathComponent(url.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(url, destination)
            return destination
        }, locationFacts: { trashLocationFacts($0.path) })
        port.move = { from, to in
            self.moveCalls.append(from)
            try FolderTrashPort.moveWithoutOverwrite(from, to)
        }
        return port
    }
}

@MainActor
func folderTrashLocationPortTests(_ check: (Bool, String) -> Void) async {
    print("iOS Trash port refusal and invalid results through injected effects")
    do {
        let f = try TrashLocationFixture()
        defer { f.cleanup() }
        let original = f.items[3].primary.url
        do {
            _ = try f.port.trash(original)
            check(false, "unconfirmed Trash location should refuse")
        } catch FolderHistoryError.trashUnavailable {
            check(f.trashCalls.isEmpty && FileManager.default.fileExists(atPath: original.path),
                  "unconfirmed Trash location refuses before invoking the effect and leaves the item untouched")
        }
        let store = f.store()
        let committer = FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe)
        var withdrawals: [FolderGroupWithdrawal] = []
        let count = try await committer.commit(groups: [f.groups[1]], items: f.items, primaryHashes: [:],
            callbacks: FolderCommitCallbacks(onGroupsWithdrawn: { withdrawals = $0 }))
        check(try count == 0 && withdrawals.first?.reason == .scanOnly(f.items[3].volumeKey, .systemTrashUnconfirmed)
              && f.trashCalls.isEmpty && (try store.records()).isEmpty,
              "commit withdraws an unconfirmed location with systemTrashUnconfirmed and no Trash effect")
    } catch { check(false, "Trash location refusal fixture: \(error)") }

    for unrelated in [false, true] {
        do {
            let f = try TrashLocationFixture()
            defer { f.cleanup() }
            f.outsideResult = true
            let other = f.root.appendingPathComponent("unrelated.jpg")
            try Data("unrelated file".utf8).write(to: other)
            if unrelated { f.unrelatedResult = other }
            let store = f.store()
            let committer = FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe)
            var failures: [FolderRemovalFailure] = []
            let count = try await committer.commit(groups: [f.groups[0]], items: f.items, primaryHashes: [:],
                callbacks: FolderCommitCallbacks(onRemovalFailed: { failures.append($0) }))
            check(try count == 0 && failures.count == 1 && (try store.records()).isEmpty,
                  "outside-storage Trash result is a failed removal without success history (unrelated: \(unrelated))")
            if case .invalidTrashResult? = failures.first?.reason {
                check(true, "outside-storage result uses existing invalidTrashResult reporting")
            } else { check(false, "outside-storage result should report invalidTrashResult") }
            check(try FileManager.default.fileExists(atPath: f.items[1].primary.url.path)
                  && (try Data(contentsOf: other)) == Data("unrelated file".utf8)
                  && f.moveCalls.count == (unrelated ? 0 : 1),
                  "invalid result restores only the identified original and never moves an unrelated file")
        } catch { check(false, "Trash location result fixture: \(error)") }
    }
}

@MainActor
func folderTrashLocationSessionTests(_ check: (Bool, String) -> Void) async {
    print("Mixed per-location authority on one volume")
    do {
        let f = try TrashLocationFixture()
        defer { f.cleanup() }
        let store = f.store()
        let bookmarks = FolderBookmarkStore(url: f.root.appendingPathComponent("bookmarks.json"),
            makeAccess: { try FolderAccess(url: $0, startAccess: { _ in true }, stopAccess: { _ in }) },
            resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
        try FolderHistoryStore.atomicWrite(JSONEncoder().encode([f.confirmed, f.unconfirmed].map {
            FolderBookmark(data: Data($0.path.utf8))
        }), bookmarks.url)
        let session = FolderLibrarySession(bookmarks: bookmarks, history: store, trashPort: f.port,
            volumeProbe: f.probe, scan: { _ in
                FolderScanResult(items: f.items, groups: f.groups, exactGroupIDs: [], crossFolderDuplicates: [],
                    roots: [FolderScannedRoot(url: f.confirmed, volume: f.probe(f.confirmed)),
                            FolderScannedRoot(url: f.unconfirmed, volume: f.probe(f.unconfirmed))],
                    issues: [], primaryHashes: [:], uniqueMetadataWithheld: 0, uniqueMetadataIDs: [],
                    imageProvider: FolderImageProvider(items: f.items), accesses: [])
            }, metadata: { _ in [:] })
        session.loadFolders()
        session.startScan()
        for _ in 0..<10_000 {
            if !session.isScanning { break }
            await Task.yield()
        }
        check(session.hasScanned && f.items[1].volumeKey == f.items[3].volumeKey,
              "mixed session fixture scanned both locations on the same VolumeKey")
        session.keepAll(group: f.groups[0].id)
        check(!session.canReviewRemoval, "confirmed root never authorizes marked items under an unconfirmed same-volume root")
        session.toggleReject(group: f.groups[0].id, frameID: f.items[1].id)
        check(session.canReviewRemoval, "mixed session can review when a confirmed location has a marked item")
        session.presentRemovalReview()
        guard let review = session.removalReview else {
            check(false, "mixed session presents a removal review"); return
        }
        check(review.summary.eligibleItemIDs == [f.items[1].id]
              && review.summary.withdrawals.first?.reason == .scanOnly(f.items[3].volumeKey, .systemTrashUnconfirmed)
              && review.summary.volumes.count == 1
              && review.summary.volumes[0].capability == .scanOnly(.systemTrashUnconfirmed),
              "mixed review aggregates the scan-only reason while admitting only the confirmed location")
        _ = await session.commitReviewed(review)
        check(f.trashCalls == [f.items[1].primary.url]
              && FileManager.default.fileExists(atPath: f.items[3].primary.url.path),
              "mixed commit re-probes members and withdraws the unconfirmed location")
        let records = try store.records()
        check(records.count == 1 && records[0].itemID == f.items[1].id,
              "confirmed iOS location records a valid same-storage Trash result")
        if let record = records.first, case .restored = try store.putBack(record.id, port: f.port) {
            check(FileManager.default.fileExists(atPath: f.items[1].primary.url.path),
                  "confirmed iOS location Put Back restores the original through the same port")
        } else { check(false, "confirmed iOS location Put Back should restore") }
    } catch { check(false, "mixed Trash location session fixture: \(error)") }
}
