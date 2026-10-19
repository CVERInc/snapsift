import Foundation
import SnapsiftCore
@testable import SnapsiftFolder

private func trashLocationFacts(_ path: String?, ubiquitous: Bool? = nil,
                                local: Bool? = true, readOnly: Bool? = false,
                                mountedReadOnly: Bool? = false,
                                fileSystem: String? = "apfs", root: Bool? = false,
                                storageGroup: String? = nil) -> VolumeFacts {
    VolumeFacts(isLocal: local, isReadOnly: readOnly, mntRdOnly: mountedReadOnly,
                fileSystemType: fileSystem, isRootFileSystem: root,
                path: path, isUbiquitousItem: ubiquitous, fileProviderStorageGroup: storageGroup)
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
    check(classifyTrashLocation(trashLocationFacts(device, storageGroup: "group.com.apple.FileProvider.LocalStorage"))
          == .removalSupported, "Trash location accepts the Files app's LocalStorage group identity")
    check(classifyTrashLocation(trashLocationFacts(device, storageGroup: "group.com.example.provider"))
          == .scanOnly(.systemTrashUnconfirmed), "Trash location refuses a readable third-party group identity")
    check(classifyTrashLocation(trashLocationFacts(device, storageGroup: nil)) == .removalSupported,
          "Unreadable group identity retains the path match; legacy providers remain subject to per-item result validation")
    check(classifyTrashLocation(trashLocationFacts(device, readOnly: true,
          storageGroup: "group.com.apple.FileProvider.LocalStorage")) == .scanOnly(.readOnly),
          "LocalStorage identity does not bypass volume rules")
    check(classifyTrashLocation(trashLocationFacts(device, ubiquitous: true,
          storageGroup: "group.com.apple.FileProvider.LocalStorage")) == .scanOnly(.systemTrashUnconfirmed),
          "LocalStorage identity does not bypass ubiquitous-item refusal")
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

func folderTrashStorageGroupProbeTests(_ check: (Bool, String) -> Void) {
    print("File Provider storage group metadata capture on all platforms")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-storage-group-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let storage = root.appendingPathComponent("Containers/Shared/AppGroup/fixture/File Provider Storage")
        let picked = storage.appendingPathComponent("picked")
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        let metadata = storage.deletingLastPathComponent()
            .appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        for group in ["group.com.apple.FileProvider.LocalStorage", "group.com.example.provider"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": group],
                                                         format: .binary, options: 0)
            try data.write(to: metadata)
            check(probeVolume(at: picked).facts.fileProviderStorageGroup == group,
                  "Volume probe captures readable storage group: \(group)")
        }
        let invalidMetadata: [[String: Any]] = [["MCMMetadataIdentifier": 42], ["OtherKey": "unrelated"]]
        for value in invalidMetadata {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: metadata)
            check(probeVolume(at: picked).facts.fileProviderStorageGroup == nil,
                  "Volume probe leaves group nil without a string MCMMetadataIdentifier")
        }
        try Data("malformed plist".utf8).write(to: metadata)
        check(probeVolume(at: picked).facts.fileProviderStorageGroup == nil,
              "Volume probe leaves group nil for malformed metadata")
        try FileManager.default.removeItem(at: metadata)
        check(probeVolume(at: picked).facts.fileProviderStorageGroup == nil,
              "Volume probe leaves group nil for missing metadata")
        let nonStorage = root.appendingPathComponent("ordinary/picked")
        try FileManager.default.createDirectory(at: nonStorage, withIntermediateDirectories: true)
        let unrelatedMetadata = nonStorage.deletingLastPathComponent()
            .appendingPathComponent(metadata.lastPathComponent)
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": "group.com.example.provider"],
                                           format: .xml, options: 0).write(to: unrelatedMetadata)
        check(probeVolume(at: nonStorage).facts.fileProviderStorageGroup == nil,
              "Volume probe ignores metadata outside a File Provider storage root")
    } catch { check(false, "storage group probe fixture: \(error)") }
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
    var resultDirectory: URL?
    var unrelatedResult: URL?
    var storageGroup: String?

    init(appGroupID: String = "fixture") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-trash-location-\(UUID())")
        storage = root.appendingPathComponent("Containers/Shared/AppGroup/\(appGroupID)/File Provider Storage")
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
        let facts = trashLocationFacts(url.path, storageGroup: storageGroup)
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
            let destination = (self.resultDirectory ?? self.trash)
                .appendingPathComponent(url.lastPathComponent)
            try FolderTrashPort.moveWithoutOverwrite(url, destination)
            return destination
        }, locationFacts: { trashLocationFacts($0.path, storageGroup: self.storageGroup) })
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
}

@MainActor
func folderTrashLookAlikePortTests(_ check: (Bool, String) -> Void) async {
    print("Legacy provider look-alike refusal and invalid result recovery")
    do {
        let f = try TrashLocationFixture(appGroupID: "third-party")
        defer { f.cleanup() }
        f.storageGroup = "group.com.example.provider"
        let original = f.items[1].primary.url
        do {
            _ = try f.port.trash(original)
            check(false, "readable third-party storage group should refuse")
        } catch FolderHistoryError.trashUnavailable {
            check(f.trashCalls.isEmpty && FileManager.default.fileExists(atPath: original.path),
                  "readable third-party storage group refuses before the Trash effect")
        }
        let store = f.store()
        let committer = FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe)
        var withdrawals: [FolderGroupWithdrawal] = []
        let count = try await committer.commit(groups: [f.groups[0]], items: f.items, primaryHashes: [:],
            callbacks: FolderCommitCallbacks(onGroupsWithdrawn: { withdrawals = $0 }))
        check(try count == 0 && withdrawals.first?.reason == .scanOnly(f.items[1].volumeKey, .systemTrashUnconfirmed)
              && f.trashCalls.isEmpty && f.moveCalls.isEmpty && (try store.records()).isEmpty
              && FileManager.default.fileExists(atPath: original.path),
              "committer withdraws readable third-party storage without effects or success history")
    } catch { check(false, "readable third-party storage fixture: \(error)") }

    for resultMode in ["provider-trash", "outside-root", "unrelated"] {
        do {
            let f = try TrashLocationFixture(appGroupID: "third-party")
            defer { f.cleanup() }
            // No readable identity: the path match reaches the per-item result gate.
            let resultDirectory = resultMode == "provider-trash"
                ? f.storage.appendingPathComponent(".Trash-provider") : f.root
            f.resultDirectory = resultDirectory
            try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
            let other = f.root.appendingPathComponent("unrelated.jpg")
            try Data("unrelated file".utf8).write(to: other)
            let unrelated = resultMode == "unrelated"
            if unrelated { f.unrelatedResult = other }
            let original = f.items[1].primary.url
            let originalBytes = try Data(contentsOf: original)
            let keeper = f.items[0].primary.url
            let keeperBytes = try Data(contentsOf: keeper)
            let store = f.store()
            let committer = FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe)
            var failures: [FolderRemovalFailure] = []
            let count = try await committer.commit(groups: [f.groups[0]], items: f.items, primaryHashes: [:],
                callbacks: FolderCommitCallbacks(onRemovalFailed: { failures.append($0) }))
            check(try count == 0 && failures.count == 1 && (try store.records()).isEmpty
                  && f.trashCalls == [original],
                  "look-alike invalid Trash result fails without success history: \(resultMode)")
            let expectedResult = unrelated ? other : resultDirectory.appendingPathComponent(original.lastPathComponent)
            if case .invalidTrashResult(let result)? = failures.first?.reason {
                check(result == expectedResult, "look-alike reports the invalidTrashResult URL: \(resultMode)")
            } else { check(false, "look-alike result should report invalidTrashResult: \(resultMode)") }
            check(try (try Data(contentsOf: original)) == originalBytes
                  && (try Data(contentsOf: keeper)) == keeperBytes
                  && (try Data(contentsOf: other)) == Data("unrelated file".utf8)
                  && f.moveCalls == (unrelated ? [] : [expectedResult]),
                  "look-alike invalid result restores only the original and leaves other files untouched: \(resultMode)")
        } catch { check(false, "look-alike Trash result fixture (\(resultMode)): \(error)") }
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
