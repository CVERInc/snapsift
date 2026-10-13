import Foundation
import Darwin
import SnapsiftCore

/// Effects are injectable so automated tests never touch the user's Trash.
@MainActor
public struct FolderTrashPort {
    public var trash: (URL) throws -> URL?
    public var move: (URL, URL) throws -> Void

    public init(trash: @escaping (URL) throws -> URL?,
                move: @escaping (URL, URL) throws -> Void = FolderTrashPort.moveWithoutOverwrite) {
        self.trash = trash
        self.move = move
    }

    public static var system: FolderTrashPort {
        FolderTrashPort(trash: { url in
            #if os(macOS)
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
            #else
            throw FolderHistoryError.trashUnavailable
            #endif
        })
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
    public let size: Int
    public let fileID: UInt64
    public let modificationDate: Date
    /// True only after a Put Back move, persisted per member for accountability.
    public var restored: Bool

    public init(member: FolderMember, trashURL: URL? = nil) {
        originalURL = member.url
        self.trashURL = trashURL
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

    public func entries() throws -> [FolderHistoryEntry] {
        try records().reversed().sorted { $0.timestamp > $1.timestamp }.map {
            FolderHistoryEntry(record: $0, putBackAvailable: canPutBack($0))
        }
    }

    public func canPutBack(_ record: FolderHistoryRecord) -> Bool {
        guard record.state == .removed, !record.members.isEmpty else { return false }
        return record.members.allSatisfy { member in
            guard !member.restored, let trash = member.trashURL,
                  let live = try? FolderMember.read(at: trash) else { return false }
            return live.volumeKey == record.volumeKey && live.fileID == member.fileID
                && live.size == member.size && live.modificationDate == member.modificationDate
                && volumeProbe(trash).volumeKey == record.volumeKey
        }
    }

    /// Never searches the Trash. A detached known volume leaves the journal
    /// pending; reconciling it as lost would discard its known recovery paths.
    @discardableResult
    public func reconcileIntent() throws -> [FolderHistoryRecord] {
        try reconcilePutBackHistory()
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
                guard let trash = member.trashURL, let live = try? FolderMember.read(at: trash) else { return false }
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
        guard canPutBack(record) else { return .unavailable }
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
                try port.move(member.trashURL!, member.originalURL)
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
                    try port.move(member.originalURL, member.trashURL!)
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
            if parent.path == ancestor.path { return false }
            ancestor = parent
        }
    }

    private func reconcilePutBackHistory() throws {
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
                if !canPutBack(record) { record.state = .rollbackFailed }
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
