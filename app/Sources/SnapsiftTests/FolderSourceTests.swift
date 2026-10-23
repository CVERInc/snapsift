import Foundation
import Darwin
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SnapsiftCore
@testable import SnapsiftFolder
import SnapsiftVision

private enum FixtureError: Error { case imageWrite, metadataWrite }

func writeFolderImage(_ url: URL, width: Int = 640, height: Int = 480,
                              variant: Bool = false, properties: [CFString: Any] = [:]) throws {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<height {
        let t = CGFloat(y) / CGFloat(height)
        ctx.setFillColor(red: 0.15 + 0.3 * t, green: 0.5 - 0.2 * t, blue: 0.65, alpha: 1)
        ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }
    for i in 0..<5 {
        ctx.setFillColor(red: CGFloat(i + 1) / 7, green: 0.7, blue: CGFloat(5 - i) / 7, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: width / 10 + i * width / 8, y: height / 4 + i * height / 14,
                                  width: width / 5, height: height / 3))
    }
    if variant {
        ctx.setFillColor(red: 0.16, green: 0.49, blue: 0.64, alpha: 1)
        ctx.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
    }
    let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil),
          let image = ctx.makeImage() else { throw FixtureError.imageWrite }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.imageWrite }
}

private func folderTemp(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func folder(_ root: URL, _ name: String) throws -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func setFinderPlist(_ value: Any, at url: URL, name: String) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    let status = url.path.withCString { path in
        name.withCString { key in
            data.withUnsafeBytes { setxattr(path, key, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
    }
    guard status == 0 else { throw FixtureError.metadataWrite }
}

private struct FolderFixtureMetadata: UniqueMetadataProbe {
    let facts: [String: LibraryMetadata]
    func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata] { facts }
}

@MainActor
func checkFolderSource() async {
    print("Folder source and detection")
    do {
        let root = try folderTemp("folder-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = try folder(root, ".hidden")
        let trash = try folder(root, ".Trashes")
        let package = try folder(root, "Library.photoslibrary")
        let nested = try folder(root, "nested")
        for directory in [hidden, trash, package] {
            try writeFolderImage(directory.appendingPathComponent("skip.jpg"))
        }
        for name in ["._appledouble.jpg", ".hidden.jpg", ".DS_Store"] {
            try writeFolderImage(root.appendingPathComponent(name))
        }
        try writeFolderImage(nested.appendingPathComponent("nested.png"))
        try writeFolderImage(root.appendingPathComponent("plain.jpg"))
        try writeFolderImage(root.appendingPathComponent("Live.JPG"))
        try Data("fake motion".utf8).write(to: root.appendingPathComponent("live.MOV"))
        try writeFolderImage(root.appendingPathComponent("Pair.jpg"))
        try Data("fake RAW".utf8).write(to: root.appendingPathComponent("PAIR.DNG"))
        try writeFolderImage(root.appendingPathComponent("Edited.jpg"))
        try Data("edit".utf8).write(to: root.appendingPathComponent("EDITED.XMP"))
        try Data("edit".utf8).write(to: root.appendingPathComponent("edited.AAE"))
        try writeFolderImage(root.appendingPathComponent("IMG_1234.jpg"))
        try writeFolderImage(root.appendingPathComponent("IMG_E1234.jpg"))
        try Data("orphan".utf8).write(to: root.appendingPathComponent("orphan.mov"))
        try Data("orphan".utf8).write(to: root.appendingPathComponent("orphan.xmp"))
        try Data("orphan".utf8).write(to: root.appendingPathComponent("other.aae"))
        try Data("video".utf8).write(to: root.appendingPathComponent("video.mp4"))
        // Symlinks must not escape the selected root or alias one item twice.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.jpg"),
                                                   withDestinationURL: root.appendingPathComponent("plain.jpg"))
        let enumeration = try FolderEnumerator.enumerate(root: root)
        let items = enumeration.items
        let names = Set(items.map { $0.primary.url.lastPathComponent })
        check(names == ["nested.png", "plain.jpg", "Live.JPG", "Pair.jpg", "Edited.jpg", "IMG_1234.jpg", "IMG_E1234.jpg"],
              "folder enumeration: hidden/package/AppleDouble/Trash/video/orphan/symlink skips, recursive image discovery")
        check(enumeration.issues.isEmpty, "folder enumeration: supported fixtures have no read issues")
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.primary.url.lastPathComponent, $0) })
        let live = byName["Live.JPG"]!, pair = byName["Pair.jpg"]!, edited = byName["Edited.jpg"]!
        let plain = byName["plain.jpg"]!
        check(Set(live.members.map { $0.url.lastPathComponent }) == ["Live.JPG", "live.MOV"],
              "folder grouping: case-insensitive Live Photo image/movie pair is one item")
        check(Set(pair.members.map { $0.url.lastPathComponent }) == ["Pair.jpg", "PAIR.DNG"]
              && pair.primary.url.lastPathComponent == "Pair.jpg" && pair.photo.uti == "public.jpeg",
              "folder grouping: RAW+JPEG uses JPEG pixels/facts/UTI for unchanged keeper ranking")
        check(edited.members.count == 3 && edited.photo.edited && edited.photo.isProtected,
              "folder grouping: XMP/AAE members make the whole photo edited and protected")
        check(names.contains("IMG_1234.jpg") && names.contains("IMG_E1234.jpg")
              && byName["IMG_E1234.jpg"]!.members.count == 1,
              "folder grouping: IMG_E1234 is a separate photo, never a sidecar")
        check(!plain.photo.favorite && !plain.photo.edited && !plain.photo.editedUndetermined
              && plain.photo.kind == 0 && plain.photo.quality == 0,
              "folder facts: favorite=false, edited=false, edit state determined, kind/quality=0 explicitly")
        check(plain.photo.documentEvalDegraded && !plain.photo.isDeletable,
              "folder facts: pixels remain unverifiable until the Vision pass runs")
        check(items.allSatisfy { $0.photo.size == $0.members.reduce(0) { $0 + $1.size } },
              "folder facts: size sums every indivisible member")
        check(items.allSatisfy { $0.id.hasPrefix("folder:") && UUID(uuidString: $0.id.components(separatedBy: "/")[0]) == nil },
              "folder identity: source prefix cannot parse as a Photos asset UUID")
        check(try FolderMember.read(at: plain.primary.url) == plain.primary,
              "folder identity: live member snapshot preserves URL, inode, volume, size and modification/creation dates")
        let renamed = root.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: plain.primary.url, to: renamed)
        guard let afterRename = try FolderEnumerator.enumerate(root: root).items.first(where: {
            $0.primary.url.path == renamed.path
        }) else { throw FixtureError.imageWrite }
        check(afterRename.primary.fileID == plain.primary.fileID && afterRename.id != plain.id,
              "folder identity: inode remains stable; a renamed directory entry gets a new scan identifier")
        try FileManager.default.moveItem(at: renamed, to: plain.primary.url)

        let hasher = FolderOriginalHasher(items: items)
        let digest = await hasher.sha256(itemIdentifier: plain.id)
        let expected = SHA256.hash(data: try Data(contentsOf: plain.primary.url)).map { String(format: "%02x", $0) }.joined()
        check(digest == expected, "folder hash: streaming digest equals SHA-256 of the complete primary file")
        let pairedDigest = await hasher.sha256(itemIdentifier: pair.id)
        check(pairedDigest == expected, "folder hash: companion bytes are excluded from primary identity")
        let plainSignals = FolderMetadataProbe.readSignals(at: plain.primary.url)
        check(plainSignals.hasTags == false && plainSignals.hasComment == false,
              "folder metadata: known-absent Finder tags/comment remain determined false")
        let missingSignals = FolderMetadataProbe.readSignals(at: root.appendingPathComponent("missing.jpg"))
        check(missingSignals.hasUniqueMetadata == nil, "folder metadata: unreadable file is undetermined, never absent")
        try setFinderPlist(["Test tag\n6"], at: pair.members.first { $0.url.pathExtension == "DNG" }!.url,
                           name: "com.apple.metadata:_kMDItemUserTags")
        let pairMetadata = await FolderMetadataProbe(items: items).metadata(for: [pair.id])
        check(pairMetadata[pair.id]?.hasDescription == true && pairMetadata[pair.id]?.albumCount == 1,
              "folder metadata: a Finder tag on a companion applies to the whole item; location plays the album role")
        try setFinderPlist("A Finder comment", at: live.primary.url,
                           name: "com.apple.metadata:kMDItemFinderComment")
        check(FolderMetadataProbe.readSignals(at: live.primary.url).hasComment == true,
              "folder metadata: Finder comment marks unique metadata")
        let unknownProbe = FolderMetadataProbe(items: items, signals: { _ in
            FolderMetadataSignals(hasTags: nil, hasComment: false)
        })
        let unknown = await unknownProbe.metadata(for: [plain.id])
        check(unknown[plain.id]?.hasDescription == nil && unknown[plain.id]?.albumCount == 1,
              "folder metadata: unavailable tag API remains undetermined with known folder membership")

        let storeURL = root.appendingPathComponent("bookmark-store/folders.json")
        let store = FolderBookmarkStore(url: storeURL)
        let bookmark = try store.add(nested)
        check(try store.load().map(\.id) == [bookmark.id], "folder bookmarks: selection persists to its dedicated store")
        let resolved = try FolderBookmarkStore(url: storeURL).access(bookmark.id)
        check(resolved.access.url.resolvingSymlinksInPath() == nested.resolvingSymlinksInPath(),
              "folder bookmarks: temp directory round-trips in a non-sandboxed process")
        resolved.access.stop()
        resolved.access.stop()
        check(!resolved.wasStale, "folder bookmarks: fresh round-trip reports not stale; access stop is idempotent")
        try store.remove(bookmark.id)
        check(try store.load().isEmpty, "folder bookmarks: removing a selection persists")
        check(FolderBookmarkStore.defaultURL.deletingLastPathComponent().lastPathComponent == "snapsift-folder-mode"
              && FolderBookmarkStore.defaultURL.lastPathComponent == "folders.json",
              "folder stores: bookmark path is separate from the Photos audit/journal/last-scan directory")

        let orientedURL = root.appendingPathComponent("oriented.jpg")
        try writeFolderImage(orientedURL, width: 160, height: 120, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+08:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture", kCGImagePropertyTIFFModel: "Camera"],
        ])
        guard let oriented = try FolderEnumerator.enumerate(root: root).items.first(where: {
            $0.primary.url.path == orientedURL.path
        }) else { throw FixtureError.imageWrite }
        check(oriented.photo.width == 120 && oriented.photo.height == 160,
              "folder facts: EXIF orientation swaps pixel dimensions")
        let date = ISO8601DateFormatter().date(from: "2020-01-01T19:04:05Z")!
        check(oriented.photo.takenAt == date.timeIntervalSince1970 && oriented.photo.originalCamera,
              "folder facts: DateTimeOriginal + offset and nonempty camera Make/Model heuristic")
        check(abs(plain.photo.takenAt - plain.primary.creationDate.timeIntervalSince1970) < 0.001,
              "folder facts: missing EXIF capture date falls back to file creation time")
        let provider = FolderImageProvider(items: [oriented])
        for (profile, side) in [(ImageRequestProfile.dHash, 9), (.featurePrint, 160), (.faceScoring, 512),
                                (.categoryLabels, 256), (.documentLocal, 512), (.documentHighQuality, 512)] {
            let image = await provider.image(for: oriented.id, profile: profile)
            check(image != nil && max(image!.width, image!.height) <= side && image!.height > image!.width,
                  "folder provider: \(profile) honors maximum target size and orientation")
        }
        let absent = await provider.image(for: "https://example.invalid/image", profile: .featurePrint)
        check(absent == nil, "folder provider: unknown/non-file identifiers never fetch pixels")

        let encodings = try folder(root, "same-stem-encodings")
        try writeFolderImage(encodings.appendingPathComponent("same.jpg"))
        try writeFolderImage(encodings.appendingPathComponent("same.png"))
        check(try FolderEnumerator.enumerate(root: encodings).items.count == 2,
              "folder grouping: same-stem JPEG/PNG stay separate; only the specified RAW pair is joined")
        try Data("ambiguous motion".utf8).write(to: encodings.appendingPathComponent("same.mov"))
        let ambiguous = try FolderEnumerator.enumerate(root: encodings)
        check(ambiguous.items.isEmpty && ambiguous.issues.count == 1,
              "folder grouping: ambiguous companion ownership is reported, never split or guessed")

        try checkFolderEnumerationReadFailures(root: root)
        try checkFolderIOSMetadata(root: root)
        try await checkFolderExactRules(root: root)
        try await checkFolderPipeline(root: root)
    } catch {
        check(false, "folder fixture setup/execution: \(error)")
    }
}

private func checkFolderIOSMetadata(root: URL) throws {
    let directory = try folder(root, "ios-metadata")
    let plain = directory.appendingPathComponent("plain.jpg")
    let tagged = directory.appendingPathComponent("tagged.jpg")
    let labeled = directory.appendingPathComponent("labeled.jpg")
    let unlabeled = directory.appendingPathComponent("unlabeled.jpg")
    let commented = directory.appendingPathComponent("commented.jpg")
    let empty = directory.appendingPathComponent("empty.jpg")
    let unexpected = directory.appendingPathComponent("unexpected.jpg")
    let malformed = directory.appendingPathComponent("malformed.jpg")
    let missing = directory.appendingPathComponent("missing.jpg")
    for url in [plain, tagged, labeled, unlabeled, commented, empty, unexpected, malformed] {
        try Data("metadata fixture".utf8).write(to: url)
    }
    let tagsKey = "com.apple.metadata:_kMDItemUserTags"
    let commentKey = "com.apple.metadata:kMDItemFinderComment"
    for (url, color) in [(labeled, UInt8(0x0c)), (unlabeled, UInt8(0))] {
        var data = Data(count: 32)
        data[0] = 0x54
        data[9] = color
        let status = url.path.withCString { path in
            data.withUnsafeBytes {
                setxattr(path, "com.apple.FinderInfo", $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
        guard status == 0 else { throw FixtureError.metadataWrite }
    }
    try setFinderPlist(["Red\n0"], at: tagged, name: tagsKey)
    try setFinderPlist("A Finder comment", at: commented, name: commentKey)
    try setFinderPlist([String](), at: empty, name: tagsKey)
    try setFinderPlist("", at: empty, name: commentKey)
    for key in [tagsKey, commentKey] {
        try setFinderPlist(42, at: unexpected, name: key)
        let data = Data([0xff, 0x00, 0xfe])
        let status = malformed.path.withCString { path in
            key.withCString { name in
                data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
            }
        }
        guard status == 0 else { throw FixtureError.metadataWrite }
    }
    for type in ["apfs", "hfs"] {
        for (url, tags, comment) in [(plain, false, false), (tagged, true, false),
                                     (labeled, true, false), (unlabeled, false, false),
                                     (commented, false, true), (empty, false, false)] {
            let signals = FolderMetadataProbe.readIOSSignals(at: url, fileSystemType: { _ in type })
            check(signals == FolderMetadataSignals(hasTags: tags, hasComment: comment),
                  "folder iOS metadata: \(type) \(url.lastPathComponent) reads real xattrs")
        }
        for url in [missing, unexpected, malformed] {
            let signals = FolderMetadataProbe.readIOSSignals(at: url, fileSystemType: { _ in type })
            check(signals == FolderMetadataSignals(hasTags: nil, hasComment: nil),
                  "folder iOS metadata: \(type) \(url.lastPathComponent) stays undetermined")
        }
    }
    for type: String? in ["exfat", "msdos", "smbfs", "fskit", "unknown", nil] {
        for url in [plain, tagged, labeled, commented] {
            let signals = FolderMetadataProbe.readIOSSignals(at: url, fileSystemType: { _ in type })
            check(signals == FolderMetadataSignals(hasTags: nil, hasComment: nil),
                  "folder iOS metadata: \(type ?? "unreadable") \(url.lastPathComponent) stays undetermined")
        }
    }
    check(FolderMetadataProbe.readIOSSignals(at: missing)
          == FolderMetadataSignals(hasTags: nil, hasComment: nil),
          "folder iOS metadata: a missing file through the default lookup stays undetermined")
    let mounted = readMountedFileSystem(at: plain)?.fileSystemType
    check(mounted != nil, "folder iOS metadata: statfs reads the fixture's own volume")
    let expected = mounted == "apfs" || mounted == "hfs" ? false : nil
    check(FolderMetadataProbe.readIOSSignals(at: plain)
          == FolderMetadataSignals(hasTags: expected, hasComment: expected),
          "folder iOS metadata: the default lookup applies the native-xattr gate")
}

@MainActor
private func checkFolderEnumerationReadFailures(root: URL) throws {
    let cloud = FolderICloudAccess(policy: .localOnly, port: .system, timeout: 0)
    let nonPhotos = try folder(root, "unreadable-non-photos")
    let project = nonPhotos.appendingPathComponent("project.sb3")
    let text = nonPhotos.appendingPathComponent("notes.txt")
    let unknown = nonPhotos.appendingPathComponent("extensionless")
    for url in [project, text, unknown] { try Data("document".utf8).write(to: url) }
    var reads: Set<URL> = []
    let excluded = try FolderEnumerator.enumerate(root: nonPhotos, cloud: cloud, readResourceValues: { url, _ in
        reads.insert(url)
        throw CocoaError(.fileReadNoPermission)
    })
    check(excluded.items.isEmpty && excluded.issues.isEmpty,
          "folder scope: failed resource reads for non-photos produce no items or skipped/unreadable issues")
    check(!reads.contains(text), "folder scope: known non-photo extensions are excluded before resource reads")
    check(reads.contains(unknown), "folder scope: a failed unknown-extension fallback is exercised without reporting it")
    check(!FolderEnumerator.shouldReportEnumerationError(at: project)
          && !FolderEnumerator.shouldReportEnumerationError(at: text)
          && !FolderEnumerator.shouldReportEnumerationError(at: unknown),
          "folder enumeration errors: non-photo and unclassified file names are out of scope")

    let photos = try folder(root, "unreadable-photo")
    let photo = photos.appendingPathComponent("photo.jpg")
    try writeFolderImage(photo)
    var photoReads = 0
    let unreadable = try FolderEnumerator.enumerate(root: photos, cloud: cloud, readResourceValues: { _, _ in
        photoReads += 1
        throw CocoaError(.fileReadNoPermission)
    })
    check(photoReads == 1 && unreadable.items.isEmpty && unreadable.issues.count == 1
          && unreadable.issues[0].url == photo && unreadable.issues[0].reason == .unreadable,
          "folder scope: a photo resource read failure still reports unreadable")
    check(FolderEnumerator.shouldReportEnumerationError(at: photo),
          "folder enumeration errors: photo names remain reportable")

    let siblings = try folder(root, "unreadable-unrelated-sibling")
    let still = siblings.appendingPathComponent("same.jpg")
    let unrelated = siblings.appendingPathComponent("same.sb3")
    try writeFolderImage(still)
    try Data("project".utf8).write(to: unrelated)
    let safe = try FolderEnumerator.enumerate(root: siblings, cloud: cloud, readResourceValues: { url, keys in
        if url == unrelated { throw CocoaError(.fileReadNoPermission) }
        return try url.resourceValues(forKeys: keys)
    })
    check(safe.issues.isEmpty && safe.items.count == 1 && safe.items[0].members.map(\.url) == [still],
          "folder scope: an unreadable non-photo never becomes a member or withholds its same-stem photo")

    for ext in ["XMP", "AAE", "MOV"] {
        let paired = try folder(root, "unreadable-companion-\(ext)")
        let image = paired.appendingPathComponent("paired.jpg")
        let companion = paired.appendingPathComponent("paired.\(ext)")
        try writeFolderImage(image)
        try Data("companion".utf8).write(to: companion)
        var companionReads = 0
        let result = try FolderEnumerator.enumerate(root: paired, cloud: cloud, readResourceValues: { url, keys in
            if url == companion {
                companionReads += 1
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: keys)
        })
        check(companionReads == 1 && result.items.isEmpty && result.issues.count == 1
              && result.issues[0].url == companion && result.issues[0].reason == .unreadable,
              "folder scope: unreadable \(ext) companion still withholds the whole photo")
        check(FolderEnumerator.shouldReportEnumerationError(at: companion),
              "folder enumeration errors: \(ext) companion names remain reportable")
    }

    let directories = try folder(root, "directory-with-non-photo-extension")
    let directory = try folder(directories, "album.txt")
    let nested = directory.appendingPathComponent("nested.jpg")
    try writeFolderImage(nested)
    let recursive = try FolderEnumerator.enumerate(root: directories, cloud: cloud)
    check(recursive.items.map(\.primary.url) == [nested] && recursive.issues.isEmpty,
          "folder scope: non-photo directory extensions never prevent recursion")
    let directoryFailure = try FolderEnumerator.enumerate(root: directories, cloud: cloud, readResourceValues: { url, keys in
        if url == directory { throw CocoaError(.fileReadNoPermission) }
        return try url.resourceValues(forKeys: keys)
    })
    check(directoryFailure.issues.count == 1 && directoryFailure.issues[0].url == directory
          && directoryFailure.issues[0].reason == .unreadable
          && FolderEnumerator.shouldReportEnumerationError(at: directory),
          "folder scope: unreadable directories remain reportable regardless of extension")
    check(FolderEnumerator.shouldReportEnumerationError(
        at: directories.appendingPathComponent("missing.txt", isDirectory: true)),
          "folder enumeration errors: a directory URL remains reportable when its file kind is unavailable")

    let fallbackRoot = try folder(root, "unknown-extension-image")
    let fallback = fallbackRoot.appendingPathComponent("extensionless")
    try writeFolderImage(fallback)
    let typed = try FolderEnumerator.enumerate(root: fallbackRoot, cloud: cloud, readResourceValues: { _, keys in
        // Borrow a real JPEG's resource type while keeping extensionless image bytes.
        try photo.resourceValues(forKeys: keys)
    })
    check(typed.items.map(\.primary.url) == [fallback] && typed.issues.isEmpty,
          "folder scope: unknown extensions retain the resource contentType image fallback")
    let failingCloud = FolderICloudAccess(policy: .localOnly, port: FolderUbiquityPort(state: { _ in
        throw CocoaError(.fileReadNoPermission)
    }, startDownload: { _ in }, evict: { _ in }), timeout: 0)
    let typedFailure = try FolderEnumerator.enumerate(root: fallbackRoot, cloud: failingCloud, readResourceValues: { _, keys in
        try photo.resourceValues(forKeys: keys)
    })
    check(typedFailure.items.isEmpty && typedFailure.issues.count == 1
          && typedFailure.issues[0].url == fallback && typedFailure.issues[0].reason == .unreadable,
          "folder scope: images established by contentType still report later read failures")
}

@MainActor
private func checkFolderExactRules(root: URL) async throws {
    let a = try folder(root, "exact-a"), b = try folder(root, "exact-b")
    for (directory, names) in [(a, ["one.jpg", "two.jpg"]), (b, ["three.jpg"])] {
        for name in names { try writeFolderImage(directory.appendingPathComponent(name)) }
    }
    let rawItems = try FolderEnumerator.enumerate(root: a).items + FolderEnumerator.enumerate(root: b).items
    let items = rawItems.map { $0.with(photo: $0.photo.with(documentEvalDegraded: false)) }
    let same = items.filter { $0.directoryURL.path == a.path }
    guard same.count == 2, let outside = items.first(where: { $0.directoryURL.path == b.path }) else {
        throw FixtureError.imageWrite
    }
    let pair = ReviewGroup(photos: same.map(\.photo), keeperID: same[0].id)
    let plainFacts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, LibraryMetadata(albumCount: 1, hasDescription: false)) })
    let normal = await seedFolderExactRejections(in: [pair], exact: [pair.id], items: items,
                                                 metadataProbe: FolderFixtureMetadata(facts: plainFacts),
                                                 documentCheck: { _ in false })
    check(normal.groups[0].rejected == [same[1].id] && normal.groups[0].autoSeeded == [same[1].id],
          "folder exact: same-folder identical items seed only the non-keeper through the shared Core pass")
    let cross = ReviewGroup(photos: [same[0].photo, outside.photo], keeperID: same[0].id)
    let crossResult = await seedFolderExactRejections(in: [cross], exact: [cross.id], items: items,
                                                      metadataProbe: FolderFixtureMetadata(facts: plainFacts),
                                                      documentCheck: { _ in false })
    check(crossResult.groups[0].rejected.isEmpty, "folder exact: a copy whose only twin is across folders is never seeded")
    let mixed = ReviewGroup(photos: items.map(\.photo), keeperID: same[0].id)
    let mixedResult = await seedFolderExactRejections(in: [mixed], exact: [mixed.id], items: items,
                                                      metadataProbe: FolderFixtureMetadata(facts: plainFacts),
                                                      documentCheck: { _ in false })
    check(mixedResult.groups[0].rejected.isEmpty, "folder exact: mixed 2+1 folder group withholds every pre-mark")
    let crossElsewhere = await seedFolderExactRejections(
        in: [pair], exact: [pair.id], items: items, crossFolderItemIDs: [same[0].id, same[1].id, outside.id],
        metadataProbe: FolderFixtureMetadata(facts: plainFacts), documentCheck: { _ in false })
    check(crossElsewhere.groups[0].rejected.isEmpty,
          "folder exact: a separately surfaced cross-folder primary match also withholds same-folder marks")
    for photo in [same[1].photo.with(favorite: true), same[1].photo.with(edited: true),
                  same[1].photo.with(isDocument: true), same[1].photo.with(documentEvalDegraded: true),
                  same[1].photo.with(editedUndetermined: true)] {
        let protected = ReviewGroup(photos: [same[0].photo, photo], keeperID: same[0].id)
        let result = await seedFolderExactRejections(in: [protected], exact: [protected.id], items: items,
                                                     metadataProbe: FolderFixtureMetadata(facts: plainFacts),
                                                     documentCheck: { _ in false })
        check(result.groups[0].rejected.isEmpty, "folder exact: protected/unverifiable item never pre-marked (\(photo.isProtected), \(photo.isUnverifiable))")
    }
    try setFinderPlist(["Test tag\n6"], at: same[1].primary.url, name: "com.apple.metadata:_kMDItemUserTags")
    let tagged = await seedFolderExactRejections(in: [pair], exact: [pair.id], items: items,
                                                 metadataProbe: FolderMetadataProbe(items: items), documentCheck: { _ in false })
    check(tagged.groups[0].rejected.isEmpty && tagged.uniqueMetadataIDs == [same[1].id],
          "folder exact: actual Finder tag marks unique metadata and blocks the seed")
    try setFinderPlist(["Other tag\n2"], at: same[0].primary.url, name: "com.apple.metadata:_kMDItemUserTags")
    let bothTagged = await seedFolderExactRejections(in: [pair], exact: [pair.id], items: items,
                                                     metadataProbe: FolderMetadataProbe(items: items), documentCheck: { _ in false })
    check(bothTagged.groups[0].rejected.isEmpty,
          "folder exact: tagged candidate stays protected even when its keeper also has tags")
    let unknownProbe = FolderMetadataProbe(items: items, signals: { _ in FolderMetadataSignals(hasTags: nil, hasComment: false) })
    let unknown = await seedFolderExactRejections(in: [pair], exact: [pair.id], items: items,
                                                  metadataProbe: unknownProbe, documentCheck: { _ in false })
    check(unknown.groups[0].rejected.isEmpty && unknown.uniqueMetadataWithheld == 1 && unknown.uniqueMetadataIDs.isEmpty,
          "folder exact: unreadable metadata blocks pre-marking without inventing a badge")
    let missingKeeperFacts = FolderFixtureMetadata(facts: [same[1].id: plainFacts[same[1].id]!])
    let missingKeeper = await seedFolderExactRejections(in: [pair], exact: [pair.id], items: items,
                                                       metadataProbe: missingKeeperFacts, documentCheck: { _ in false })
    check(missingKeeper.groups[0].rejected.isEmpty, "folder exact: undetermined keeper metadata also withholds")
}

@MainActor
private func checkFolderPipeline(root: URL) async throws {
    let sameRoot = try folder(root, "pipeline-same")
    let original = sameRoot.appendingPathComponent("first.png")
    try writeFolderImage(original)
    try FileManager.default.copyItem(at: original, to: sameRoot.appendingPathComponent("second.png"))
    let same = try await FolderScanPipeline.scan(roots: [sameRoot])
    defer { same.accesses.forEach { $0.stop() } }
    checkNeedsVision(same.groups.count == 1 && same.exactGroupIDs == [same.groups[0].id]
          && same.groups[0].rejected.count == 1 && same.groups[0].rejected == same.groups[0].autoSeeded,
          "folder pipeline: generated same-folder byte copies are exact and seed one non-keeper")
    check(same.items.allSatisfy { !$0.photo.documentEvalDegraded && $0.photo.sharpness > 0 },
          "folder pipeline: shared Vision supplies determined document facts and sharpness")
    check(same.roots.count == 1 && same.roots[0].url == sameRoot
          && same.roots[0].volume.capability == probeVolume(at: sameRoot).capability,
          "folder pipeline: returns the S7 capability for every scanned root")
    let crossRoot = try folder(root, "pipeline-cross")
    try FileManager.default.copyItem(at: original, to: crossRoot.appendingPathComponent("third.png"))
    let cross = try await FolderScanPipeline.scan(roots: [sameRoot, crossRoot])
    defer { cross.accesses.forEach { $0.stop() } }
    check(cross.crossFolderDuplicates.count == 1 && cross.crossFolderDuplicates[0].itemIDs.count == 3
          && cross.crossFolderDuplicates[0].folderKeys.count == 2 && cross.roots.count == 2,
          "folder pipeline: mixed same/cross-folder primary-byte copies surface as data")
    checkNeedsVision(cross.exactGroupIDs.count == 1 && cross.groups.allSatisfy { $0.rejected.isEmpty && $0.autoSeeded.isEmpty },
          "folder pipeline: mixed-folder exact badge is retained and every pre-mark withheld")
    let aliasRoot = try folder(root, "pipeline-hardlink")
    let alias = aliasRoot.appendingPathComponent("linked.png")
    guard original.path.withCString({ source in alias.path.withCString { link(source, $0) } }) == 0 else {
        throw FixtureError.imageWrite
    }
    let linked = try await FolderScanPipeline.scan(roots: [sameRoot, aliasRoot])
    defer { linked.accesses.forEach { $0.stop() } }
    check(linked.items.count == 3 && Set(linked.items.map(\.id)).count == 3
          && linked.crossFolderDuplicates.count == 1 && linked.groups.allSatisfy { $0.autoSeeded.isEmpty },
          "folder identity: cross-folder hard-link entries remain distinct and withhold every pre-mark")
    let nearRoot = try folder(root, "pipeline-near")
    try writeFolderImage(nearRoot.appendingPathComponent("first.png"))
    try writeFolderImage(nearRoot.appendingPathComponent("second.png"), variant: true)
    let nearItems = try FolderEnumerator.enumerate(root: nearRoot).items
    check(cluster(nearItems.map(\.photo), gapSec: 3, sizeTol: 0.10, maxSpan: 30).count == 1,
          "folder pipeline fixture: near-identical generated images qualify for shared time clustering")
    let near = try await FolderScanPipeline.scan(roots: [nearRoot])
    defer { near.accesses.forEach { $0.stop() } }
    checkNeedsVision(near.groups.count == 1 && near.groups[0].photos.count == 2 && near.groups[0].confidentDupe,
          "folder pipeline: shared content clustering and neural gate group near-identical generated images")
    check(near.exactGroupIDs.isEmpty && near.groups[0].rejected.isEmpty && Set(near.primaryHashes.values).count == 2,
          "folder pipeline: perceptual near-copies with different bytes are never pre-marked")
    let companionRoot = try folder(root, "pipeline-companions")
    for name in ["one.jpg", "two.jpg"] { try writeFolderImage(companionRoot.appendingPathComponent(name)) }
    try Data("motion only on one copy".utf8).write(to: companionRoot.appendingPathComponent("one.mov"))
    let companions = try await FolderScanPipeline.scan(roots: [companionRoot])
    defer { companions.accesses.forEach { $0.stop() } }
    check(companions.exactGroupIDs.isEmpty && companions.groups.allSatisfy { $0.rejected.isEmpty },
          "folder pipeline: matching primary bytes never certify or pre-mark unverified companions")
    let sidecarRoot = try folder(root, "pipeline-sidecar")
    for name in ["one.jpg", "two.jpg"] { try writeFolderImage(sidecarRoot.appendingPathComponent(name)) }
    try Data("edit".utf8).write(to: sidecarRoot.appendingPathComponent("two.xmp"))
    let sidecar = try await FolderScanPipeline.scan(roots: [sidecarRoot])
    defer { sidecar.accesses.forEach { $0.stop() } }
    check(sidecar.items.first { $0.primary.url.lastPathComponent == "two.jpg" }?.photo.isProtected == true
          && sidecar.groups.allSatisfy { $0.rejected.isEmpty },
          "folder pipeline: sidecar edit protection survives Vision and ranking; item never pre-marked")
    try Data("changed bytes".utf8).write(to: original)
    guard let changedItem = same.items.first(where: { $0.primary.url.path == original.path }) else {
        throw FixtureError.imageWrite
    }
    let changedHash = await FolderOriginalHasher(items: same.items).sha256(itemIdentifier: changedItem.id)
    check(changedHash == nil,
          "folder hash: a primary whose scan-time identity/size/mtime changed cannot be certified")
}
