import Foundation
import Darwin

struct FolderDownloadPersistenceError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

/// One store per host/session, shared with its scan pipeline. Uses the host's
/// existing folder bookmarks; no additional grants or per-file bookmarks.
public final class FolderDownloadStore: @unchecked Sendable {
    private struct Entry: Codable {
        let file: FolderDownloadedFile
        let folderID: UUID
        let relativePath: String

        func file(at root: URL) throws -> FolderDownloadedFile {
            let url = root.appendingPathComponent(relativePath).standardizedFileURL
            let prefix = root.standardizedFileURL.path == "/" ? "/" : root.standardizedFileURL.path + "/"
            guard url.path.hasPrefix(prefix) else {
                throw FolderSourceError.unreadableFile
            }
            let original = file.member
            let member = FolderMember(url: url, fileID: original.fileID, volumeKey: original.volumeKey,
                                      size: original.size, modificationDate: original.modificationDate,
                                      creationDate: original.creationDate)
            return FolderDownloadedFile(url: url, size: file.size, member: member, receiptID: file.receiptID)
        }
    }

    public let url: URL
    private let bookmarks: FolderBookmarkStore
    private let lock = NSLock()
    private var entries: [Entry]
    private var writeError: Error?

    public init(url: URL, bookmarks: FolderBookmarkStore) {
        self.url = url
        self.bookmarks = bookmarks
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    }

    /// A failed write leaves the in-memory receipt available for retry/reporting.
    public var persistenceError: Error? {
        lock.lock(); defer { lock.unlock() }
        return writeError
    }

    /// Unavailable grants retain the last known URL for reporting. Eviction
    /// always requires resolving the original folder bookmark again.
    public var downloadedFiles: [FolderDownloadedFile] {
        lock.lock(); defer { lock.unlock() }
        var accesses: [UUID: Result<FolderAccess, Error>] = [:]
        defer { for result in accesses.values { (try? result.get())?.stop() } }
        return entries.map { entry in
            guard let access = try? access(entry.folderID, cached: &accesses) else { return entry.file }
            return (try? entry.file(at: access.url)) ?? entry.file
        }.sorted { $0.url.path < $1.url.path }
    }

    /// Validate all roots and the destination before starting any downloads.
    func prepare(roots: [URL]) throws -> [URL: UUID] {
        lock.lock(); defer { lock.unlock() }
        var available: [String: UUID] = [:]
        for bookmark in try bookmarks.load() {
            guard let resolved = try? bookmarks.access(bookmark.id) else { continue }
            available[resolved.access.url.standardizedFileURL.path] = bookmark.id
            resolved.access.stop()
        }
        var selected: [URL: UUID] = [:]
        for root in roots {
            let url = root.standardizedFileURL
            guard let id = available[url.path] else { throw FolderSourceError.bookmarkNotFound }
            selected[url] = id
        }
        try save()
        return selected
    }

    func record(_ file: FolderDownloadedFile, roots: [URL: UUID]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let root = roots.keys.filter({ file.url.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") })
            .max(by: { $0.path.count < $1.path.count }), let folderID = roots[root] else {
            throw FolderDownloadPersistenceError(underlying: FolderSourceError.bookmarkNotFound)
        }
        let entry = Entry(file: file, folderID: folderID,
                          relativePath: String(file.url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1)))
        entries.removeAll { $0.file.url == file.url || ($0.folderID == folderID && $0.relativePath == entry.relativePath) }
        entries.append(entry)
        try save()
    }

    /// Retains failed evictions for retry; removes evicted, changed, missing and
    /// no-longer-ubiquitous receipts. Reuses the scan's coordinated eviction gate.
    public func evictDownloadedFiles(ubiquityPort: FolderUbiquityPort = .system) async -> [FolderICloudEvictionResult] {
        await Task.detached(priority: .utility) { self.evict(nil, port: ubiquityPort) }.value
    }

    func evict(_ files: [FolderDownloadedFile]?, port: FolderUbiquityPort) -> [FolderICloudEvictionResult] {
        lock.lock(); defer { lock.unlock() }
        var accesses: [UUID: Result<FolderAccess, Error>] = [:]
        defer { for result in accesses.values { (try? result.get())?.stop() } }
        let selected = entries.filter { entry in
            files == nil || files!.contains { $0.receiptID == entry.file.receiptID }
        }.sorted { $0.file.url.path < $1.file.url.path }
        var results: [FolderICloudEvictionResult] = []
        for entry in selected {
            var reportedURL = entry.file.url
            do {
                let access = try access(entry.folderID, cached: &accesses)
                let file = try entry.file(at: access.url)
                reportedURL = file.url
                let result = FolderICloudAccess.evict([file], port: port, skipNonlocal: true)[0]
                var info = stat()
                let missing = file.url.path.withCString { lstat($0, &info) } != 0 && errno == ENOENT
                if result.outcome == .evicted || result.outcome == .changed
                    || result.outcome == .noLongerUbiquitous || missing {
                    let previous = entries
                    entries.removeAll { $0.folderID == entry.folderID && $0.relativePath == entry.relativePath }
                    do { try save() }
                    catch { entries = previous; throw error }
                }
                results.append(result)
            } catch {
                results.append(FolderICloudEvictionResult(url: reportedURL, outcome: .failed(error.localizedDescription)))
            }
        }
        return results
    }

    private func access(_ folderID: UUID, cached: inout [UUID: Result<FolderAccess, Error>]) throws -> FolderAccess {
        if let result = cached[folderID] { return try result.get() }
        let result = Result { try bookmarks.access(folderID).access }
        cached[folderID] = result
        return try result.get()
    }

    private func save() throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            writeError = nil
        } catch {
            writeError = error
            throw FolderDownloadPersistenceError(underlying: error)
        }
    }
}
