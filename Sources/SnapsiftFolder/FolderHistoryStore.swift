import Foundation
import Darwin
import SnapsiftCore

@MainActor
public struct FolderResolvedItem {
    public let url: URL
    public let stopAccessing: () -> Void

    public init(url: URL, stopAccessing: @escaping () -> Void = {}) {
        self.url = url
        self.stopAccessing = stopAccessing
    }
}

/// Effects are injectable so automated tests never touch the user's Trash.
@MainActor
public struct FolderTrashPort {
    public var trash: (URL) throws -> URL?
    public var move: (URL, URL) throws -> Void
    public var bookmark: (URL) -> Data? = { _ in nil }
    public var resolve: (Data) -> FolderResolvedItem? = { _ in nil }
    public var verifyPrimary: (URL, String) -> Bool = { _, _ in true }
    var readMember: (URL) -> FolderMember? = { try? FolderMember.read(at: $0) }
    var validateResult: (URL, URL?) -> Bool = { _, _ in true }

    public init(trash: @escaping (URL) throws -> URL?,
                move: @escaping (URL, URL) throws -> Void = FolderTrashPort.moveWithoutOverwrite) {
        self.trash = trash
        self.move = move
        #if os(iOS)
        verifyPrimary = Self.verifyPrimaryHash
        #endif
    }

    public static var system: FolderTrashPort {
        #if os(iOS)
        var port = confirmedLocation(trash: { url in
            // S1: plan/research/folder-mode-trash-volumes.md, iOS 2026-10-19:
            // NSFileCoordinator around trashItem deadlocks; use plain trashItem.
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }, locationFacts: { probeVolume(at: $0).facts })
        port.bookmark = { try? $0.bookmarkData() }
        port.resolve = { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
                  !stale, url.startAccessingSecurityScopedResource() else { return nil }
            return FolderResolvedItem(url: url, stopAccessing: { url.stopAccessingSecurityScopedResource() })
        }
        return port
        #else
        return FolderTrashPort(trash: { url in
            #if os(macOS)
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
            #else
            throw FolderHistoryError.trashUnavailable
            #endif
        })
        #endif
    }

    static func confirmedLocation(trash: @escaping (URL) throws -> URL?,
                                  locationFacts: @escaping (URL) -> VolumeFacts) -> FolderTrashPort {
        var port = FolderTrashPort(trash: { url in
            guard url.isFileURL, classifyTrashLocation(locationFacts(url)) == .removalSupported else {
                throw FolderHistoryError.trashUnavailable
            }
            return try trash(url)
        })
        port.validateResult = validateTrashLocation
        return port
    }

    func trashRecording(_ url: URL) throws -> (url: URL?, bookmark: Data?) {
        let data = bookmark(url)
        return (try trash(url), data)
    }

    static func verifyPrimaryHash(_ url: URL, _ expected: String) -> Bool {
        guard let member = try? FolderMember.read(at: url),
              let digest = FolderOriginalHasher.hash(member) else { return false }
        return digest == expected
    }

    func usableTrash(_ member: FolderHistoryMember) -> (item: FolderResolvedItem, live: FolderMember)? {
        if let url = member.trashURL, let live = readMember(url) {
            return (FolderResolvedItem(url: url), live)
        }
        guard let data = member.trashBookmark, let item = resolve(data) else { return nil }
        guard validateTrashLocation(sourceURL: member.originalURL, resultingURL: item.url),
              let live = readMember(item.url) else {
            item.stopAccessing()
            return nil
        }
        return (item, live)
    }

    /// Exclusive rename prevents overwriting even if a destination appears
    /// between the preflight and the move. Trash and originals share a volume.
    public nonisolated static func moveWithoutOverwrite(_ source: URL, _ destination: URL) throws {
        try moveWithoutOverwrite(source, destination, exclusiveRename: Darwin.renamex_np)
    }

    public nonisolated static func moveWithoutOverwrite(
        _ source: URL, _ destination: URL,
        exclusiveRename: (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32,
        rename: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = Darwin.rename
    ) throws {
        guard source.isFileURL, destination.isFileURL else { throw FolderHistoryError.invalidPath }
        try source.path.withCString { from in
            try destination.path.withCString { to in
                if exclusiveRename(from, to, UInt32(RENAME_EXCL)) == 0 { return }
                let exclusiveError = errno
                guard exclusiveError == ENOTSUP || exclusiveError == EINVAL else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(exclusiveError))
                }
                // exFAT does not support RENAME_EXCL; reserve the destination exclusively.
                let descriptor = open(to, O_CREAT | O_EXCL | O_WRONLY, mode_t(S_IRUSR | S_IWUSR))
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var placeholder = stat()
                let statResult = fstat(descriptor, &placeholder)
                let statError = errno
                let closeResult = close(descriptor)
                let closeError = errno
                guard statResult == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(statError)) }

                func removePlaceholder() {
                    var current = stat()
                    if lstat(to, &current) == 0,
                       current.st_dev == placeholder.st_dev, current.st_ino == placeholder.st_ino,
                       (current.st_mode & S_IFMT) == S_IFREG, current.st_size == 0 {
                        _ = unlink(to)
                    }
                }
                guard closeResult == 0 else {
                    removePlaceholder()
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(closeError))
                }
                guard rename(from, to) == 0 else {
                    let renameError = errno
                    removePlaceholder()
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
                }
            }
        }
    }
}

public enum FolderHistoryError: Error {
    case trashUnavailable, invalidPath, pendingIntent, entryNotFound
}

public enum FolderRecordState: String, Codable, Sendable {
    case pending, removed, rollbackFailed, locationUnknown, trashMissing, restoring, restored
}

public struct FolderHistoryMember: Codable, Sendable {
    public let originalURL: URL
    public var trashURL: URL?
    /// Opaque bookmark of the original item, taken just before trash. On iOS,
    /// this is the only way to reach an item trashed outside the picked scope
    /// (iCloud Drive). About 1 KB per member (measured 1.07 KB on macOS; iOS
    /// size pending measurement), encoded as base64 in the history JSON.
    public var trashBookmark: Data?
    public let size: Int
    public let fileID: UInt64
    public let modificationDate: Date
    /// True only after a Put Back move, persisted per member for accountability.
    public var restored: Bool

    public init(member: FolderMember, trashURL: URL? = nil, trashBookmark: Data? = nil) {
        originalURL = member.url
        self.trashURL = trashURL
        self.trashBookmark = trashBookmark
        size = member.size
        fileID = member.fileID
        modificationDate = member.modificationDate
        restored = false
    }
}

public struct FolderHistoryRecord: Codable, Identifiable, Sendable {
    /// Unique per removal attempt; reconciliation is idempotent after append.
    public let id: UUID
    public let itemID: String
    public let timestamp: String
    public let volumeKey: VolumeKey
    public let primarySHA256: String
    public let reason: DeletionReason
    public var members: [FolderHistoryMember]
    public var state: FolderRecordState

    public init(id: UUID = UUID(), item: FolderItem, timestamp: String,
                primarySHA256: String, reason: DeletionReason) {
        self.id = id
        itemID = item.id
        self.timestamp = timestamp
        volumeKey = item.volumeKey
        self.primarySHA256 = primarySHA256
        self.reason = reason
        // Stable, primary-first order also places editing sidecars after pixels.
        members = ([item.primary] + item.members.filter { $0.url != item.primary.url }
            .sorted { $0.url.path < $1.url.path }).map { FolderHistoryMember(member: $0) }
        state = .pending
    }
}

public struct FolderHistoryEntry: Identifiable, Sendable {
    public var id: UUID { record.id }
    public let record: FolderHistoryRecord
    public let putBackAvailable: Bool
}

public enum FolderPutBackResult {
    case restored
    case unavailable
    case conflict([URL])
    case parentMissing([URL])
    case failed(String)
    case rollbackFailed([URL], String)
}

/// Atomic folder-only stores, in the same area as folder bookmarks. No fixed
/// retention; no Photos log/intent or scan-snapshot path is referenced.
@MainActor
public final class FolderHistoryStore {
    public nonisolated static var directory: URL { FolderBookmarkStore.defaultURL.deletingLastPathComponent() }
    public let historyURL: URL
    public let intentURL: URL
    private let write: (Data, URL) throws -> Void
    private let volumeProbe: (URL) -> VolumeProbeResult

    public init(historyURL: URL = FolderHistoryStore.directory.appendingPathComponent("history.json"),
                intentURL: URL = FolderHistoryStore.directory.appendingPathComponent("pending-removal.json"),
                write: @escaping (Data, URL) throws -> Void = FolderHistoryStore.atomicWrite,
                volumeProbe: @escaping (URL) -> VolumeProbeResult = probeVolume) {
        self.historyURL = historyURL
        self.intentURL = intentURL
        self.write = write
        self.volumeProbe = volumeProbe
    }

    public nonisolated static func atomicWrite(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func records() throws -> [FolderHistoryRecord] { try read(historyURL) }
    public func pendingIntent() throws -> [FolderHistoryRecord] { try read(intentURL) }
    public func writeIntent(_ records: [FolderHistoryRecord]) throws { try save(records, to: intentURL) }
    public func clearIntent() throws {
        if folderPathExists(intentURL) { try FileManager.default.removeItem(at: intentURL) }
    }

    public func append(_ records: [FolderHistoryRecord]) throws {
        guard !records.isEmpty else { return }
        var history = try self.records()
        let logged = Set(history.map(\.id))
        history.append(contentsOf: records.filter { !logged.contains($0.id) })
        try save(history, to: historyURL)
    }

    public func entries(port: FolderTrashPort? = nil) throws -> [FolderHistoryEntry] {
        try records().reversed().sorted { $0.timestamp > $1.timestamp }.map {
            FolderHistoryEntry(record: $0, putBackAvailable: canPutBack($0, port: port))
        }
    }

    public func canPutBack(_ record: FolderHistoryRecord, port: FolderTrashPort? = nil) -> Bool {
        let port = port ?? .system
        // Listing never re-hashes; Put Back verifies the primary before moving.
        guard let items = restorableItems(record, port: port, verifyPrimary: false) else { return false }
        defer { items.forEach { $0.stopAccessing() } }
        return true
    }

    private func restorableItems(_ record: FolderHistoryRecord, port: FolderTrashPort,
                                 verifyPrimary: Bool) -> [FolderResolvedItem]? {
        guard record.state == .removed, !record.members.isEmpty else { return nil }
        var items: [FolderResolvedItem] = []
        var valid = false
        defer { if !valid { items.forEach { $0.stopAccessing() } } }
        for member in record.members {
            guard !member.restored, let usable = port.usableTrash(member) else { return nil }
            items.append(usable.item)
            let trash = usable.item.url
            let live = usable.live
            guard live.volumeKey == record.volumeKey, live.fileID == member.fileID,
                  live.size == member.size, live.modificationDate == member.modificationDate,
                  volumeProbe(trash).volumeKey == record.volumeKey else { return nil }
        }
        guard !verifyPrimary || port.verifyPrimary(items[0].url, record.primarySHA256) else { return nil }
        valid = true
        return items
    }

    /// Never searches the Trash. A detached known volume leaves the journal
    /// pending; reconciling it as lost would discard its known recovery paths.
    @discardableResult
    public func reconcileIntent(port: FolderTrashPort? = nil) throws -> [FolderHistoryRecord] {
        let port = port ?? .system
        try reconcilePutBackHistory(port: port)
        let pending = try pendingIntent()
        var booked: [FolderHistoryRecord] = []
        var deferred: [FolderHistoryRecord] = []
        let logged = Set(try records().map(\.id))
        for var record in pending where !logged.contains(record.id) {
            let originals = record.members.map { originalMatches($0, volume: record.volumeKey) }
            if originals.allSatisfy({ $0 }) { continue }
            let mounted = record.members.contains { member in
                volumeMounted(at: member.trashURL ?? member.originalURL, key: record.volumeKey)
                    || volumeMounted(at: member.originalURL, key: record.volumeKey)
            }
            guard mounted else { deferred.append(record); continue }
            let known = record.members.allSatisfy { $0.trashURL != nil }
            let valid = record.members.allSatisfy { member in
                guard let usable = port.usableTrash(member) else { return false }
                defer { usable.item.stopAccessing() }
                let trash = usable.item.url
                let live = usable.live
                #if os(iOS)
                guard validateTrashLocation(sourceURL: member.originalURL, resultingURL: trash) else { return false }
                #endif
                return validateTrashResult(sourceVolumeKey: record.volumeKey, resultingURL: trash)
                    && live.fileID == member.fileID && live.size == member.size
                    && live.modificationDate == member.modificationDate
            }
            if valid { record.state = .removed }
            else if record.members.contains(where: { member in
                member.trashURL.map { folderPathExists($0) } == true
            }) { record.state = .rollbackFailed }
            else { record.state = known ? .trashMissing : .locationUnknown }
            booked.append(record)
        }
        try append(booked)
        if deferred.isEmpty { try clearIntent() }
        else { try writeIntent(deferred) }
        return booked
    }

    /// Parents must already exist. Recreating a user-removed directory could
    /// restore into an intentionally abandoned location or a changed mount.
    public func putBack(_ id: UUID, port: FolderTrashPort? = nil) throws -> FolderPutBackResult {
        let port = port ?? .system
        var history = try records()
        guard let index = history.firstIndex(where: { $0.id == id }) else {
            throw FolderHistoryError.entryNotFound
        }
        var record = history[index]
        guard let accessed = restorableItems(record, port: port, verifyPrimary: true) else { return .unavailable }
        // Keep the verified route and access through moves and partial-failure rollback.
        defer { accessed.forEach { $0.stopAccessing() } }
        let conflicts = record.members.map(\.originalURL).filter(folderPathExists)
        guard conflicts.isEmpty else { return .conflict(conflicts) }
        let parents = record.members.map { $0.originalURL.deletingLastPathComponent() }
        let missing = parents.filter { parent in
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory)
                || !directory.boolValue || volumeProbe(parent).volumeKey != record.volumeKey
        }
        guard missing.isEmpty else { return .parentMissing(missing) }
        record.state = .restoring
        history[index] = record
        try save(history, to: historyURL) // Refuse any move if the state cannot be recorded.
        var moved: [Int] = []
        do {
            for memberIndex in record.members.indices {
                let member = record.members[memberIndex]
                guard !folderPathExists(member.originalURL) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try port.move(accessed[memberIndex].url, member.originalURL)
                moved.append(memberIndex)
                record.members[memberIndex].restored = true
                history[index] = record
                try save(history, to: historyURL)
            }
        } catch {
            let failure = String(describing: error)
            var stranded: [URL] = []
            for memberIndex in moved.reversed() {
                let member = record.members[memberIndex]
                do {
                    try port.move(member.originalURL, accessed[memberIndex].url)
                    record.members[memberIndex].restored = false
                } catch { stranded.append(member.originalURL) }
            }
            record.state = stranded.isEmpty ? .removed : .rollbackFailed
            history[index] = record
            try save(history, to: historyURL)
            return stranded.isEmpty ? .failed(failure) : .rollbackFailed(stranded, failure)
        }
        record.state = .restored
        history[index] = record
        try save(history, to: historyURL)
        return .restored
    }

    private func originalMatches(_ member: FolderHistoryMember, volume: VolumeKey) -> Bool {
        guard let live = try? FolderMember.read(at: member.originalURL) else { return false }
        return live.volumeKey == volume && live.fileID == member.fileID
            && live.size == member.size && live.modificationDate == member.modificationDate
    }

    private func volumeMounted(at path: URL, key: VolumeKey) -> Bool {
        // Missing originals/parents do not imply an unmounted volume. Probe
        // ancestors, stopping at the root; never enumerate or search the Trash.
        var ancestor = path
        while true {
            if volumeProbe(ancestor).volumeKey == key { return true }
            let parent = ancestor.deletingLastPathComponent()
            // At the root, older Foundation (macOS 14) returns "/.." from
            // deletingLastPathComponent, so comparing paths alone never ends.
            if ancestor.pathComponents.count <= 1 || parent.path == ancestor.path { return false }
            ancestor = parent
        }
    }

    private func reconcilePutBackHistory(port: FolderTrashPort) throws {
        var history = try records()
        var changed = false
        for index in history.indices where history[index].state == .restoring {
            var record = history[index]
            guard record.members.contains(where: { volumeMounted(at: $0.originalURL, key: record.volumeKey) }) else { continue }
            for memberIndex in record.members.indices {
                record.members[memberIndex].restored = originalMatches(record.members[memberIndex], volume: record.volumeKey)
            }
            if record.members.allSatisfy(\.restored) { record.state = .restored }
            else if record.members.allSatisfy({ !$0.restored }) {
                record.state = .removed
                if !canPutBack(record, port: port) { record.state = .rollbackFailed }
            } else { record.state = .rollbackFailed }
            history[index] = record
            changed = true
        }
        if changed { try save(history, to: historyURL) }
    }

    private func read(_ url: URL) throws -> [FolderHistoryRecord] {
        guard folderPathExists(url) else { return [] }
        return try JSONDecoder().decode([FolderHistoryRecord].self, from: Data(contentsOf: url))
    }

    private func save(_ records: [FolderHistoryRecord], to url: URL) throws {
        try write(JSONEncoder().encode(records), url)
    }
}

/// lstat also catches dangling links: an existing directory entry conflicts.
func folderPathExists(_ url: URL) -> Bool {
    var info = stat()
    return url.isFileURL && url.path.withCString { lstat($0, &info) } == 0
}
