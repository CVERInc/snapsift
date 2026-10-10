import Foundation

public struct FolderBookmark: Codable, Identifiable {
    public let id: UUID
    public let data: Data

    public init(id: UUID = UUID(), data: Data) {
        self.id = id
        self.data = data
    }
}

public enum FolderSourceError: Error, Equatable {
    case notLocalDirectory
    case bookmarkNotFound
    case unreadableFile
    case volumeIdentityUnavailable
    case invalidImage
}

/// A successful start is stopped exactly once, including on error/deinit.
/// Non-sandboxed macOS URLs can be readable even when start returns false.
public final class FolderAccess {
    public let url: URL
    private let started: Bool
    private let lock = NSLock()
    private var stopped = false

    public init(url: URL) throws {
        guard url.isFileURL else { throw FolderSourceError.notLocalDirectory }
        self.url = url
        started = url.startAccessingSecurityScopedResource()
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw FolderSourceError.notLocalDirectory
            }
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            stopped = true
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let shouldStop = started && !stopped
        stopped = true
        lock.unlock()
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }

    deinit { stop() }
}

/// Folder selection has its own Application Support directory. This store
/// never references the Photos audit, intent, or scan-snapshot stores.
public final class FolderBookmarkStore {
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("snapsift-folder-mode", isDirectory: true)
            .appendingPathComponent("folders.json")
    }

    public init(url: URL = FolderBookmarkStore.defaultURL) { self.url = url }

    public func load() throws -> [FolderBookmark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([FolderBookmark].self, from: Data(contentsOf: url))
    }

    @discardableResult
    public func add(_ folder: URL) throws -> FolderBookmark {
        let access = try FolderAccess(url: folder)
        defer { access.stop() }
        let bookmark = FolderBookmark(data: try Self.bookmarkData(for: folder))
        var stored = try load()
        stored.append(bookmark)
        try save(stored)
        return bookmark
    }

    public func remove(_ id: UUID) throws { try save(load().filter { $0.id != id }) }

    /// Resolving a stale bookmark refreshes it while its access is held.
    /// The caller retains the access for the entire use of the selected root.
    public func access(_ id: UUID) throws -> (access: FolderAccess, wasStale: Bool) {
        var stored = try load()
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            throw FolderSourceError.bookmarkNotFound
        }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        // iOS document-provider bookmarks preserve the URL's granted scope;
        // the explicit withSecurityScope option is macOS-only.
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let folder = try URL(resolvingBookmarkData: stored[index].data, options: options,
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        let access = try FolderAccess(url: folder)
        do {
            if stale {
                stored[index] = FolderBookmark(id: id, data: try Self.bookmarkData(for: folder))
                try save(stored)
            }
            return (access, stale)
        } catch {
            access.stop()
            throw error
        }
    }

    private func save(_ bookmarks: [FolderBookmark]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(bookmarks).write(to: url, options: .atomic)
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        #if os(macOS)
        do {
            return try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // A non-sandboxed process may not have a sandbox extension to
            // encode. A regular bookmark still resolves its chosen folder;
            // FolderAccess balances scope whenever the resolved URL grants it.
            return try url.bookmarkData(options: [.minimalBookmark],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        #else
        return try url.bookmarkData(options: [.minimalBookmark],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
}
