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
    for home in ["/var/mobile", "/Users/fixture"] {
        for prefix in ["", "/private"] {
            let documents = prefix + home + "/Library/Mobile Documents"
            let drive = documents + "/com~apple~CloudDocs"
            for suffix in ["", "/picked", "/picked/photo.jpg"] {
                for ubiquitous in [nil, true, false] as [Bool?] {
                    check(classifyTrashLocation(trashLocationFacts(drive + suffix, ubiquitous: ubiquitous))
                          == (ubiquitous == false ? .scanOnly(.systemTrashUnconfirmed) : .removalSupported),
                          "iCloud Drive root/folder/member requires no contradictory ubiquitous fact")
                }
            }
            for path in [documents, documents + "/iCloud~com~x~y/picked", drive + "-other/picked"] {
                check(classifyTrashLocation(trashLocationFacts(path, ubiquitous: true)) == .scanOnly(.systemTrashUnconfirmed),
                      "iCloud siblings and Mobile Documents stay scan-only")
            }
            check(classifyTrashLocation(trashLocationFacts(drive, ubiquitous: true, readOnly: true)) == .scanOnly(.readOnly),
                  "iCloud Drive does not bypass volume rules")
            let source = URL(fileURLWithPath: drive + "/picked/photo.jpg")
            check(validateTrashLocation(sourceURL: source,
                  resultingURL: URL(fileURLWithPath: home + "/Library/Mobile Documents/.Trash/photo.jpg")),
                  "iCloud Trash accepts Mobile Documents/.Trash across /private aliases")
            for path in [drive + "/.Trash/photo.jpg", documents + "/elsewhere/photo.jpg",
                         documents + "/.Trash", documents + "/.Trash/../photo.jpg"] {
                check(!validateTrashLocation(sourceURL: source, resultingURL: URL(fileURLWithPath: path)),
                      "iCloud Trash rejects results outside the strict Mobile Documents/.Trash root")
            }
        }
    }
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

@MainActor
private final class ICloudTrashFixture {
    let root: URL
    let source: URL
    let trash: URL
    let items: [FolderItem]
    let group: ReviewGroup
    var active: [URL: Int] = [:]
    var starts = 0
    var stops = 0
    var events: [String] = []
    var moves: [(URL, URL)] = []
    var missingBookmark = false
    var outsideRoot = false
    var differentResult = true
    var directReadable = false
    var resolvedURL: URL?
    var failTrashAt: Int?
    var failMoveAt: Int?
    var trashCount = 0
    var scopedMoves = true

    init(companion: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-icloud-trash-\(UUID())")
        let documents = root.appendingPathComponent("Library/Mobile Documents")
        source = documents.appendingPathComponent("com~apple~CloudDocs/picked")
        trash = documents.appendingPathComponent(".Trash")
        for url in [source, trash] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var items: [FolderItem] = []
        for name in ["keeper", "candidate"] {
            let url = source.appendingPathComponent(name + ".jpg")
            try Data(name.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                                   ofItemAtPath: url.path)
            let primary = try FolderMember.read(at: url)
            var members = [primary]
            if companion && name == "candidate" {
                let movie = source.appendingPathComponent(name + ".mov")
                try Data("companion".utf8).write(to: movie)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                                                       ofItemAtPath: movie.path)
                members.append(try FolderMember.read(at: movie))
            }
            let photo = Photo(uuid: url.path, filename: url.lastPathComponent, takenAt: 0,
                              width: 16, height: 16, size: primary.size, uti: "public.jpeg")
            items.append(FolderItem(photo: photo, primary: primary, members: members,
                                    directoryURL: source, folderKey: source.path))
        }
        self.items = items
        var group = ReviewGroup(photos: items.map(\.photo), keeperID: items[0].id)
        group.rejected = [items[1].id]
        self.group = group
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func destination(_ original: URL) -> URL { trash.appendingPathComponent(original.lastPathComponent) }
    func probe(_ url: URL) -> VolumeProbeResult {
        let p = probeVolume(at: url)
        let facts = trashLocationFacts(url.path, ubiquitous: true)
        return VolumeProbeResult(facts: facts, volumeKey: p.volumeKey, displayName: "iCloud Drive",
                                 volumeURL: p.volumeURL, capability: classifyTrashLocation(facts))
    }
    func store() -> FolderHistoryStore {
        FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                           intentURL: root.appendingPathComponent("intent.json"))
    }
    var port: FolderTrashPort {
        var port = FolderTrashPort.confirmedLocation(trash: { url in
            self.events.append("trash:\(url.lastPathComponent)")
            self.trashCount += 1
            if self.failTrashAt == self.trashCount { throw FolderHistoryError.trashUnavailable }
            let destination = self.destination(url)
            try FolderTrashPort.moveWithoutOverwrite(url, destination)
            return self.differentResult ? self.trash.appendingPathComponent("unreadable-" + url.lastPathComponent) : destination
        }, locationFacts: { trashLocationFacts($0.path, ubiquitous: true) })
        port.bookmark = { url in
            self.events.append("bookmark:\(url.lastPathComponent)")
            guard !self.missingBookmark, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Data(url.path.utf8)
        }
        port.resolve = { data in
            let original = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
            let url = self.resolvedURL ?? (self.outsideRoot ? self.root.appendingPathComponent("outside.jpg") : self.destination(original))
            self.starts += 1
            self.active[url, default: 0] += 1
            return FolderResolvedItem(url: url, stopAccessing: {
                self.stops += 1
                self.active[url, default: 0] -= 1
            })
        }
        port.readMember = { url in
            guard self.directReadable || self.active[url, default: 0] > 0 else { return nil }
            return try? FolderMember.read(at: url)
        }
        port.move = { from, to in
            self.moves.append((from, to))
            self.scopedMoves = self.scopedMoves && (self.directReadable
                || self.active[from, default: 0] > 0 || self.active[to, default: 0] > 0)
            if self.failMoveAt == self.moves.count { throw FolderHistoryError.trashUnavailable }
            try FolderTrashPort.moveWithoutOverwrite(from, to)
        }
        return port
    }
    func remove(into store: FolderHistoryStore) async throws -> Int {
        try await FolderCommitter(history: store, trashPort: port, volumeProbe: probe)
            .commit(groups: [group], items: items, primaryHashes: [:])
    }
    var accessBalanced: Bool { starts == stops && active.values.allSatisfy { $0 == 0 } }
}

@MainActor
func folderICloudTrashBookmarkTests(_ check: (Bool, String) -> Void) async {
    print("iCloud Trash bookmarks, scoped verification and Put Back")
    for differentResult in [false, true] {
        do {
            let f = try ICloudTrashFixture()
            defer { f.cleanup() }
            f.differentResult = differentResult
            let store = f.store()
            let original = f.items[1].primary.url
            let bytes = try Data(contentsOf: original)
            let summary = FolderCommitter(history: store, trashPort: f.port, volumeProbe: f.probe)
                .preCommitSummary(groups: [f.group], items: f.items)
            check(summary.eligibleItemIDs == [f.items[1].id] && summary.volumes.first?.capability == .removalSupported,
                  "iCloud Drive members report removalSupported")
            let count = try await f.remove(into: store)
            let records = try store.records()
            check(count == 1 && records.count == 1, "unreadable iCloud Trash result succeeds through its original bookmark")
            guard let record = records.first else { continue }
            check(record.members[0].trashBookmark == Data(original.path.utf8)
                  && record.members[0].trashURL == f.destination(original)
                  && f.events == ["bookmark:candidate.jpg", "trash:candidate.jpg"] && f.accessBalanced,
                  "bookmark is captured before Trash; history records the verified resolved URL and releases access")
            check(try store.canPutBack(record, port: f.port) && store.entries(port: f.port).first?.putBackAvailable == true
                  && f.accessBalanced, "history checks use scoped bookmark reads")
            try store.writeIntent([record])
            try FileManager.default.removeItem(at: store.historyURL)
            let reconciled = try store.reconcileIntent(port: f.port)
            check(reconciled.first?.state == .removed && f.accessBalanced,
                  "pending intent reconciles unreadable Trash through the recorded bookmark")
            if case .restored = try store.putBack(record.id, port: f.port) {
                check(try Data(contentsOf: original) == bytes && f.moves.count == 1
                      && f.moves[0].0 == f.destination(original) && f.moves[0].1 == original
                      && f.scopedMoves && f.accessBalanced,
                      "Put Back moves from the resolved URL to the exact original with its bytes and scoped access")
            } else { check(false, "iCloud bookmark Put Back should restore") }
            var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
            var members = old["members"] as! [[String: Any]]
            members[0].removeValue(forKey: "trashBookmark")
            old["members"] = members
            let decoded = try JSONDecoder().decode(FolderHistoryRecord.self,
                from: JSONSerialization.data(withJSONObject: old))
            check(decoded.members[0].trashBookmark == nil, "old history JSON decodes without trashBookmark")
        } catch { check(false, "iCloud bookmark fixture: \(error)") }
    }
    for mode in ["outside", "missing", "identity"] {
        do {
            let f = try ICloudTrashFixture()
            defer { f.cleanup() }
            let store = f.store()
            _ = try await f.remove(into: store)
            var record = try store.records()[0]
            if mode == "outside" { f.outsideRoot = true }
            if mode == "missing" { record.members[0].trashBookmark = nil }
            if mode == "identity" {
                let replacement = f.trash.appendingPathComponent("replacement")
                try Data("different".utf8).write(to: replacement)
                try FileManager.default.removeItem(at: f.destination(f.items[1].primary.url))
                try FileManager.default.moveItem(at: replacement, to: f.destination(f.items[1].primary.url))
            }
            try FolderHistoryStore.atomicWrite(JSONEncoder().encode([record]), store.historyURL)
            check(!store.canPutBack(record, port: f.port), "invalid bookmark history is not restorable: \(mode)")
            if case .unavailable = try store.putBack(record.id, port: f.port) {
                check(f.moves.isEmpty && f.accessBalanced, "unrestorable bookmark refuses moves and releases access: \(mode)")
            } else { check(false, "invalid bookmark must refuse Put Back: \(mode)") }
        } catch { check(false, "iCloud bookmark refusal fixture: \(error)") }
    }
    for mode in ["outside", "missing", "trash-failure", "put-back-failure"] {
        do {
            let f = try ICloudTrashFixture(companion: true)
            defer { f.cleanup() }
            let store = f.store()
            if mode == "outside" { f.outsideRoot = true }
            if mode == "missing" { f.missingBookmark = true }
            if mode == "trash-failure" { f.failTrashAt = 2 }
            let count = try await f.remove(into: store)
            if mode == "put-back-failure" {
                let record = try store.records()[0]
                f.failMoveAt = 2
                if case .failed = try store.putBack(record.id, port: f.port) {
                    check(try f.moves.count == 3 && f.moves[2].0 == f.items[1].primary.url
                          && f.moves[2].1 == f.destination(f.items[1].primary.url)
                          && store.canPutBack(try store.records()[0], port: f.port),
                          "partial Put Back failure rolls back into the resolved Trash URL")
                } else { check(false, "partial Put Back should fail and roll back") }
            } else {
                check(count == 0, "commit refuses an unusable result or partial Trash failure: \(mode)")
                if mode == "trash-failure" {
                    check(f.moves.count == 1 && f.moves[0].0 == f.destination(f.items[1].primary.url)
                          && FileManager.default.fileExists(atPath: f.items[1].primary.url.path),
                          "partial removal rolls back through the resolved access")
                } else {
                    check(try f.moves.isEmpty && !(try store.records()).contains { $0.state == .removed },
                          "unusable bookmark never moves an unverified item or records successful removal")
                }
            }
            check(f.accessBalanced && f.scopedMoves, "all access ends after successful or failed rollback: \(mode)")
        } catch { check(false, "iCloud bookmark rollback fixture: \(error)") }
    }
}

@MainActor
func folderTrashDirectRouteTests(_ check: (Bool, String) -> Void) async {
    print("Readable Trash URLs take priority over bookmarks")
    for mode in ["restore", "trash-rollback", "put-back-rollback"] {
        do {
            let f = try ICloudTrashFixture(companion: true)
            defer { f.cleanup() }
            f.directReadable = true
            f.differentResult = false
            // Resolving this bookmark would fail the location gate.
            f.outsideRoot = true
            if mode == "trash-rollback" { f.failTrashAt = 2 }
            let store = f.store()
            let count = try await f.remove(into: store)
            if mode == "trash-rollback" {
                check(count == 0 && f.moves.count == 1 && f.starts == 0,
                      "removal rollback uses readable trashURL without resolving its bookmark")
                continue
            }
            let record = try store.records()[0]
            check(store.canPutBack(record, port: f.port) && f.starts == 0,
                  "history availability reads trashURL without resolving its bookmark")
            try store.writeIntent([record])
            try FileManager.default.removeItem(at: store.historyURL)
            let recovered = try store.reconcileIntent(port: f.port)
            check(recovered.first?.state == .removed && f.starts == 0,
                  "history validity reads trashURL without resolving its bookmark")
            if mode == "put-back-rollback" { f.failMoveAt = 2 }
            let result = try store.putBack(record.id, port: f.port)
            if mode == "restore", case .restored = result {
                check(f.moves.count == 2 && f.starts == 0,
                      "Put Back uses readable trashURL without resolving its bookmark")
            } else if mode == "put-back-rollback", case .failed = result {
                check(f.moves.count == 3 && f.moves[2].1 == record.members[0].trashURL && f.starts == 0,
                      "Put Back rollback uses the direct Trash path without resolving its bookmark")
            } else { check(false, "direct route result: \(mode)") }
        } catch { check(false, "direct Trash route fixture: \(error)") }
    }
}

@MainActor
func folderTrashRestoreIdentityTests(_ check: (Bool, String) -> Void) async {
    print("Restore identity and primary hash through both Trash routes")
    for direct in [false, true] {
        for mode in ["inode", "bytes", "matching", "unreadable-hash", "default", "companion-inode"] {
            do {
                let companion = mode == "companion-inode"
                let f = try ICloudTrashFixture(companion: companion)
                defer { f.cleanup() }
                let store = f.store()
                _ = try await f.remove(into: store)
                let resolutionsBeforeRestore = f.starts
                var record = try store.records()[0]
                let memberIndex = companion ? 1 : 0
                let member = record.members[memberIndex]
                let originalTrash = member.trashURL!
                let alternate = f.trash.appendingPathComponent("alternate-" + originalTrash.lastPathComponent)
                let bytes = try Data(contentsOf: originalTrash)
                if mode == "inode" || companion {
                    try bytes.write(to: alternate)
                } else {
                    try FolderTrashPort.moveWithoutOverwrite(originalTrash, alternate)
                    if mode == "bytes" || mode == "default" {
                        let handle = try FileHandle(forWritingTo: alternate)
                        try handle.write(contentsOf: Data(repeating: 120, count: bytes.count))
                        try handle.close()
                    }
                }
                try FileManager.default.setAttributes([.modificationDate: member.modificationDate],
                                                       ofItemAtPath: alternate.path)
                let live = try FolderMember.read(at: alternate)
                check(live.size == member.size && live.modificationDate == member.modificationDate
                      && ((live.fileID != member.fileID) == (mode == "inode" || companion)),
                      "restore fixture isolates the changed inode or bytes: \(direct), \(mode)")
                f.directReadable = direct
                if direct { record.members[memberIndex].trashURL = alternate }
                try FolderHistoryStore.atomicWrite(JSONEncoder().encode([record]), store.historyURL)
                var port = f.port
                let resolve = port.resolve
                port.resolve = { data in
                    let original = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
                    f.resolvedURL = original == member.originalURL ? alternate : nil
                    return resolve(data)
                }
                var hashURLs: [URL] = []
                var scopedHash = true
                if mode != "default" {
                    port.verifyPrimary = { url, expected in
                        hashURLs.append(url)
                        scopedHash = scopedHash && (direct || f.active[url, default: 0] > 0)
                        if mode == "unreadable-hash" { return false }
                        return FolderTrashPort.verifyPrimaryHash(url, expected)
                    }
                }
                let shouldRestore = mode == "matching" || mode == "default"
                // Listing checks identity only; the primary hash is verified by Put Back itself.
                let listable = mode != "inode" && !companion
                check(store.canPutBack(record, port: port) == listable && hashURLs.isEmpty && f.accessBalanced,
                      "history availability enforces restore identity without hashing: \(direct), \(mode)")
                let result = try store.putBack(record.id, port: port)
                if shouldRestore, case .restored = result {
                    let expectedBytes = mode == "default" ? Data(repeating: 120, count: bytes.count) : bytes
                    check(try f.moves.count == 1 && f.moves[0].0 == alternate && f.moves[0].1 == member.originalURL
                          && Data(contentsOf: member.originalURL) == expectedBytes,
                          "matching hash restores; non-iOS default does not re-hash: \(direct), \(mode)")
                } else if !shouldRestore, case .unavailable = result {
                    check(try f.moves.isEmpty && store.canPutBack(try store.records()[0], port: port) == listable
                          && !FileManager.default.fileExists(atPath: member.originalURL.path),
                          "mismatched or unreadable Trash item remains not restorable with no move: \(direct), \(mode)")
                } else { check(false, "restore identity result: \(direct), \(mode)") }
                let shouldHash = mode != "default" && mode != "inode" && !companion
                check((!hashURLs.isEmpty) == shouldHash && hashURLs.allSatisfy { $0 == alternate }
                      && scopedHash && f.scopedMoves && f.accessBalanced && (!direct || f.starts == resolutionsBeforeRestore),
                      "hash and moves share the selected route and access; all members validate before any move")
            } catch { check(false, "restore identity fixture (\(direct), \(mode)): \(error)") }
        }
    }
    #if !os(iOS)
    check(FolderTrashPort.system.verifyPrimary(URL(fileURLWithPath: "/missing-trash-fixture"), "mismatch"),
          "non-iOS system port does not read or hash the primary")
    #endif
}
