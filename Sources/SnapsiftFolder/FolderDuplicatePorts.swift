import Foundation
import Darwin
import CryptoKit
import SnapsiftCore

/// Streaming SHA-256 of the primary's complete bytes (1 MiB buffers).
/// Companions are NOT included: this port describes primary-file identity,
/// not interchangeability of a Live Photo/RAW pair. The scan's exact-certifying
/// adapter withholds multi-member items, matching the PhotoKit safety gate.
public struct FolderOriginalHasher: OriginalBytesHasher {
    private let items: [String: FolderItem]

    public init(items: [FolderItem]) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func sha256(itemIdentifier: String) async -> String? {
        guard let member = items[itemIdentifier]?.primary, !Task.isCancelled else { return nil }
        // Disk reads stay off the main actor and cooperative pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.hash(member))
            }
        }
    }

    private static func hash(_ member: FolderMember) -> String? {
        guard member.url.isFileURL else { return nil }
        let descriptor = member.url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        func matches() -> Bool {
            fstat(descriptor, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
                && UInt64(info.st_ino) == member.fileID && info.st_size == member.size
                && FolderMember.date(info.st_mtimespec) == member.modificationDate
        }
        guard matches(), (try? FolderMember.read(at: member.url)) == member else { return nil }
        do {
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            guard matches(), (try? FolderMember.read(at: member.url)) == member else { return nil }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }
}

public struct FolderMetadataSignals: Equatable, Sendable {
    public let hasTags: Bool?
    public let hasComment: Bool?

    public init(hasTags: Bool?, hasComment: Bool?) {
        self.hasTags = hasTags
        self.hasComment = hasComment
    }

    public var hasUniqueMetadata: Bool? {
        if hasTags == true || hasComment == true { return true }
        guard hasTags != nil, hasComment != nil else { return nil }
        return false
    }
}

/// Folder identity plays the album role, enforced by the scan's location gate.
/// Finder signals on ANY companion apply to the whole indivisible item.
public struct FolderMetadataProbe: UniqueMetadataProbe {
    private let items: [String: FolderItem]
    private let signals: (URL) -> FolderMetadataSignals

    public init(items: [FolderItem],
                signals: @escaping (URL) -> FolderMetadataSignals = FolderMetadataProbe.readSignals) {
        self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.signals = signals
    }

    public func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata] {
        var result: [String: LibraryMetadata] = [:]
        for id in itemIdentifiers {
            guard let item = items[id] else { continue }
            let memberSignals = item.members.map { signals($0.url).hasUniqueMetadata }
            let unique: Bool? = memberSignals.contains(true) ? true
                : (memberSignals.contains(nil) ? nil : false)
            result[id] = LibraryMetadata(albumCount: 1, hasDescription: unique)
        }
        return result
    }

    public static func readSignals(at url: URL) -> FolderMetadataSignals {
        guard url.isFileURL else { return FolderMetadataSignals(hasTags: nil, hasComment: nil) }
        #if os(macOS)
        let tags: Bool?
        do {
            var freshURL = url
            freshURL.removeCachedResourceValue(forKey: .tagNamesKey)
            let values = try freshURL.resourceValues(forKeys: [.tagNamesKey])
            if let names = values.tagNames { tags = !names.isEmpty }
            else {
                // Foundation may omit the tagNames value on an untagged file.
                // Confirm absence via the tag xattr; an API/read error is nil.
                tags = plistHasContent(url, name: "com.apple.metadata:_kMDItemUserTags")
            }
        } catch { tags = nil }
        return FolderMetadataSignals(
            hasTags: tags,
            hasComment: plistHasContent(url, name: "com.apple.metadata:kMDItemFinderComment"))
        #else
        // Finder's tag API is unavailable on iOS; never invent absence.
        return FolderMetadataSignals(hasTags: nil, hasComment: nil)
        #endif
    }

    #if os(macOS)
    private static func plistHasContent(_ url: URL, name: String) -> Bool? {
        guard url.isFileURL else { return nil }
        return url.path.withCString { path in
            name.withCString { key in
                let count = getxattr(path, key, nil, 0, 0, XATTR_NOFOLLOW)
                if count < 0 { return errno == ENOATTR ? false : nil }
                if count == 0 { return false }
                // Finder metadata is small; reject implausible/unbounded input.
                guard count <= 1_048_576 else { return nil }
                var data = Data(count: count)
                let actual = data.withUnsafeMutableBytes {
                    getxattr(path, key, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
                }
                guard actual == count,
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                else { return nil }
                if let names = plist as? [String] { return !names.isEmpty }
                if let comment = plist as? String { return !comment.isEmpty }
                return nil
            }
        }
    }
    #endif
}
