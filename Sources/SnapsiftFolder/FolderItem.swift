import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore

/// Immutable scan-time facts used by the folder committer's later live gate.
public struct FolderMember: Equatable, Sendable {
    public let url: URL
    public let fileID: UInt64
    public let volumeKey: VolumeKey
    public let size: Int
    public let modificationDate: Date
    public let creationDate: Date

    public static func read(at url: URL) throws -> FolderMember {
        guard url.isFileURL else { throw FolderSourceError.unreadableFile }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, let size = Int(exactly: info.st_size) else {
            throw FolderSourceError.unreadableFile
        }
        guard let volume = probeVolume(at: url).volumeKey else {
            throw FolderSourceError.volumeIdentityUnavailable
        }
        return FolderMember(url: url, fileID: UInt64(info.st_ino), volumeKey: volume,
                            size: size, modificationDate: date(info.st_mtimespec),
                            creationDate: date(info.st_birthtimespec))
    }

    static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}

public struct FolderItem: Identifiable, Sendable {
    public var id: String { photo.uuid }
    public let photo: Photo
    public let primary: FolderMember
    public let members: [FolderMember]
    public let directoryURL: URL
    /// Volume + directory inode: aliases of the same directory are one location.
    public let folderKey: String
    public var volumeKey: VolumeKey { primary.volumeKey }

    public func with(photo: Photo) -> FolderItem {
        FolderItem(photo: photo, primary: primary, members: members,
                   directoryURL: directoryURL, folderKey: folderKey)
    }

    static func build(members: [FolderMember], primary: FolderMember) throws -> FolderItem {
        guard let source = CGImageSourceCreateWithURL(primary.url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let type = CGImageSourceGetType(source) as String?,
              UTType(type)?.conforms(to: .image) == true else {
            throw FolderSourceError.invalidImage
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swap = (5...8).contains(orientation)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let captureDate = exifDate(exif) ?? (primary.creationDate.timeIntervalSince1970 > 0
                                           ? primary.creationDate : primary.modificationDate)
        // Non-empty camera Make AND Model is a ranking heuristic, not a
        // provenance guarantee. All facts/UTI come from the display primary.
        let camera = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel].allSatisfy {
            !(tiff[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let edited = members.contains { ["xmp", "aae"].contains($0.url.pathExtension.lowercased()) }
        let size = try members.reduce(0) { total, member in
            let sum = total.addingReportingOverflow(member.size)
            guard !sum.overflow else { throw FolderSourceError.unreadableFile }
            return sum.partialValue
        }
        let directory = primary.url.deletingLastPathComponent()
        var info = stat()
        guard directory.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else { throw FolderSourceError.unreadableFile }
        let folderKey = "\(primary.volumeKey.rawValue):inode:\(info.st_ino)"
        // Distinguish directory entries for hard links to the same inode;
        // otherwise a cross-folder alias would disappear before the location gate.
        let entry = Data(primary.url.lastPathComponent.utf8).base64EncodedString()
        let id = "folder:\(primary.volumeKey.rawValue):inode:\(primary.fileID):entry:\(info.st_ino):\(entry)"
        let photo = Photo(uuid: id, filename: primary.url.lastPathComponent,
                          takenAt: captureDate.timeIntervalSince1970,
                          width: swap ? height : width, height: swap ? width : height,
                          size: size, uti: type, kind: 0, favorite: false, quality: 0,
                          edited: edited, isDocument: false, sharpness: 0,
                          originalCamera: camera, documentEvalDegraded: true,
                          editedUndetermined: false)
        return FolderItem(photo: photo, primary: primary, members: members,
                          directoryURL: directory, folderKey: folderKey)
    }

    private static func exifDate(_ exif: [CFString: Any]) -> Date? {
        guard let string = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return formatter.date(from: string + offset)
        }
        // EXIF without an offset represents camera-local wall time.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: string)
    }
}

public struct FolderEnumerationIssue: Sendable {
    public let url: URL
    public let reason: Reason
    public enum Reason: Sendable { case unreadable, invalidImage, ambiguousMembers }
}

public struct FolderEnumerationResult {
    public let items: [FolderItem]
    public let issues: [FolderEnumerationIssue]
}

public enum FolderEnumerator {
    /// Pair only same-directory, case-insensitive stems. Other same-stem
    /// encodings stay separate unless a RAW+JPEG/HEIC relation joins them.
    /// HEIC/HEIF, then JPEG, then other non-RAW, then RAW is the primary order.
    /// RAW+JPEG therefore has JPEG pixels/facts/UTI for the unchanged Core rank.
    public static func enumerate(root: URL) throws -> FolderEnumerationResult {
        guard root.isFileURL else { throw FolderSourceError.notLocalDirectory }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true, rootValues.isPackage != true else {
            throw FolderSourceError.notLocalDirectory
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                      .isPackageKey, .isHiddenKey, .contentTypeKey]
        var issues: [FolderEnumerationIssue] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                issues.append(FolderEnumerationIssue(url: url, reason: .unreadable))
                return true
            }) else { throw FolderSourceError.notLocalDirectory }
        var buckets: [String: [URL]] = [:]
        var types: [URL: UTType] = [:]
        for case let entry as URL in enumerator {
            let url = entry.standardizedFileURL
            if Task.isCancelled { throw CancellationError() }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent
                if name.hasPrefix(".") || values.isHidden == true || values.isPackage == true
                    || values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                // Extension UTType first also admits RAW companions whose
                // bytes cannot be decoded (their JPEG primary supplies facts).
                let type = UTType(filenameExtension: url.pathExtension) ?? values.contentType
                let isImage = type?.conforms(to: .image) == true
                let companion = ["mov", "xmp", "aae"].contains(url.pathExtension.lowercased())
                guard isImage || companion else { continue }
                if isImage { types[url] = type }
                let key = url.deletingLastPathComponent().path + "/"
                    + url.deletingPathExtension().lastPathComponent.lowercased()
                buckets[key, default: []].append(url)
            } catch {
                issues.append(FolderEnumerationIssue(url: url, reason: .unreadable))
            }
        }
        var items: [FolderItem] = []
        for key in buckets.keys.sorted() {
            let urls = buckets[key]!.sorted { $0.path < $1.path }
            let images = urls.filter { types[$0] != nil }.sorted {
                let a = primaryPriority(types[$0]!), b = primaryPriority(types[$1]!)
                return a == b ? $0.path < $1.path : a > b
            }
            guard !images.isEmpty else { continue } // orphan companions
            let raw = images.filter { types[$0]!.conforms(to: .rawImage) }
            let processed = images.filter { primaryPriority(types[$0]!) >= 2 }
            let photoFiles: [[URL]]
            if !raw.isEmpty && !processed.isEmpty {
                let pair = Set(raw + processed)
                photoFiles = [images.filter { pair.contains($0) }]
                    + images.filter { !pair.contains($0) }.map { [$0] }
            } else { photoFiles = images.map { [$0] } }
            let companions = urls.filter { types[$0] == nil }
            if !companions.isEmpty && photoFiles.count > 1 {
                // Do not guess which still owns motion/edit metadata or share
                // one member between two separately removable items.
                issues.append(FolderEnumerationIssue(url: images[0], reason: .ambiguousMembers))
                continue
            }
            for photo in photoFiles {
                let primaryURL = photo[0]
                do {
                    let members = try (photo + companions).map { try FolderMember.read(at: $0) }
                    let primary = members.first { $0.url == primaryURL }!
                    items.append(try FolderItem.build(members: members, primary: primary))
                } catch {
                    issues.append(FolderEnumerationIssue(url: primaryURL,
                                                         reason: (error as? FolderSourceError) == .invalidImage
                                                         ? .invalidImage : .unreadable))
                }
            }
        }
        return FolderEnumerationResult(items: items.sorted {
            $0.photo.takenAt == $1.photo.takenAt ? $0.id < $1.id : $0.photo.takenAt < $1.photo.takenAt
        }, issues: issues)
    }

    private static func primaryPriority(_ type: UTType) -> Int {
        if type.conforms(to: .heic) || type.identifier == "public.heif" { return 3 }
        if type.conforms(to: .jpeg) { return 2 }
        return type.conforms(to: .rawImage) ? 0 : 1
    }
}
