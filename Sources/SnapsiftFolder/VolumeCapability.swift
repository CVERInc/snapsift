import Foundation
import Darwin

/// Signals used to decide whether a scanned volume can safely move items to
/// the system Trash.
public struct VolumeFacts: Equatable, Sendable {
    public let isLocal: Bool?
    public let isReadOnly: Bool?
    public let mntRdOnly: Bool?
    public let fileSystemType: String?
    public let isRootFileSystem: Bool?

    public init(isLocal: Bool? = nil,
                isReadOnly: Bool? = nil,
                mntRdOnly: Bool? = nil,
                fileSystemType: String? = nil,
                isRootFileSystem: Bool? = nil) {
        self.isLocal = isLocal
        self.isReadOnly = isReadOnly
        self.mntRdOnly = mntRdOnly
        self.fileSystemType = fileSystemType
        self.isRootFileSystem = isRootFileSystem
    }
}

public enum VolumeCapabilityReason: Equatable, Sendable {
    case networkVolume
    case readOnly
    case unsupportedFilesystemType
    case signalsUnavailable
}

public enum VolumeCapability: Equatable, Sendable {
    case removalSupported
    case scanOnly(VolumeCapabilityReason)
}

/// Classifies only positively confirmed local, writable filesystems measured
/// as supporting the per-volume Trash behavior required by Folder Mode.
public func classifyVolume(_ facts: VolumeFacts) -> VolumeCapability {
    guard facts.isRootFileSystem != nil else {
        return .scanOnly(.signalsUnavailable)
    }
    guard let isLocal = facts.isLocal,
          let isReadOnly = facts.isReadOnly,
          let mntRdOnly = facts.mntRdOnly,
          let fileSystemType = facts.fileSystemType else {
        return .scanOnly(.signalsUnavailable)
    }

    let fileSystem = fileSystemType.lowercased()
    let networkFileSystems: Set<String> = ["smbfs", "nfs", "afp"]
    if !isLocal || networkFileSystems.contains(fileSystem) {
        return .scanOnly(.networkVolume)
    }
    if isReadOnly || mntRdOnly {
        return .scanOnly(.readOnly)
    }

    let supportedFileSystems: Set<String> = ["apfs", "hfs", "exfat", "msdos"]
    guard supportedFileSystems.contains(fileSystem) else {
        return .scanOnly(.unsupportedFilesystemType)
    }

    // The startup filesystem and writable local non-root volumes use the same
    // allow-list. The root signal is still required; its absence is not a
    // positive classification.
    return .removalSupported
}

/// Opaque identity for a mounted volume, suitable for same-volume checks.
public struct VolumeKey: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Facts and display information captured from a file or folder URL.
public struct VolumeProbeResult {
    public let facts: VolumeFacts
    public let volumeKey: VolumeKey?
    public let displayName: String?
    public let volumeURL: URL?

    public var capability: VolumeCapability { classifyVolume(facts) }

    public init(facts: VolumeFacts,
                volumeKey: VolumeKey?,
                displayName: String?,
                volumeURL: URL?) {
        self.facts = facts
        self.volumeKey = volumeKey
        self.displayName = displayName
        self.volumeURL = volumeURL
    }
}

/// Reads Foundation volume properties and the mounted filesystem flags/type.
/// Any unavailable signal stays nil, which makes the classifier return
/// scan-only.
public func probeVolume(at url: URL) -> VolumeProbeResult {
    let keys: Set<URLResourceKey> = [
        .volumeIsLocalKey,
        .volumeIsReadOnlyKey,
        .volumeIsRootFileSystemKey,
        .volumeURLKey,
        .volumeUUIDStringKey,
        .volumeIdentifierKey,
        .volumeNameKey,
    ]

    guard let values = try? url.resourceValues(forKeys: keys) else {
        return VolumeProbeResult(facts: VolumeFacts(), volumeKey: nil,
                                 displayName: nil, volumeURL: nil)
    }

    // Foundation names the `volumeURLKey` resource value `volume` in Swift.
    let volumeURL = values.volume
    // statfs the item itself, never `volumeURL`: for anything on the startup
    // Data volume Foundation reports `/`, the sealed read-only system volume,
    // which would make every startup-volume folder scan-only.
    guard let mountedFacts = readMountedFileSystem(at: url) else {
        return VolumeProbeResult(
            facts: VolumeFacts(),
            volumeKey: makeVolumeKey(uuidString: values.volumeUUIDString,
                                     identifier: values.volumeIdentifier),
            displayName: values.volumeName,
            volumeURL: volumeURL
        )
    }

    let facts = VolumeFacts(
        isLocal: values.volumeIsLocal,
        isReadOnly: values.volumeIsReadOnly,
        mntRdOnly: mountedFacts.isReadOnly,
        fileSystemType: mountedFacts.fileSystemType,
        isRootFileSystem: values.volumeIsRootFileSystem
    )
    return VolumeProbeResult(
        facts: facts,
        volumeKey: makeVolumeKey(uuidString: values.volumeUUIDString,
                                 identifier: values.volumeIdentifier),
        displayName: values.volumeName,
        volumeURL: volumeURL
    )
}

private func makeVolumeKey(uuidString: String?, identifier: Any?) -> VolumeKey? {
    if let uuidString, !uuidString.isEmpty {
        return VolumeKey(rawValue: "uuid:\(uuidString.lowercased())")
    }
    if let number = identifier as? NSNumber {
        return VolumeKey(rawValue: "number:\(number.stringValue)")
    }
    if let string = identifier as? String, !string.isEmpty {
        return VolumeKey(rawValue: "string:\(string)")
    }
    if let uuid = identifier as? UUID {
        return VolumeKey(rawValue: "uuid:\(uuid.uuidString.lowercased())")
    }
    if let data = identifier as? Data {
        let encoded = data.map { String(format: "%02x", $0) }.joined()
        return VolumeKey(rawValue: "data:\(encoded)")
    }
    return nil
}

private func readMountedFileSystem(at url: URL) -> (isReadOnly: Bool, fileSystemType: String)? {
    var info = statfs()
    let result = url.path.withCString { statfs($0, &info) }
    guard result == 0 else { return nil }

    let mountedReadOnly = (info.f_flags & UInt32(MNT_RDONLY)) != 0
    let fileSystemType = withUnsafeBytes(of: info.f_fstypename) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return (mountedReadOnly, fileSystemType)
}
