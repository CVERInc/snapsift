import Foundation

/// A same-volume result is insufficient on iOS: app containers share a volume.
func validateTrashLocation(sourceURL: URL, resultingURL: URL?) -> Bool {
    guard let root = trashRoot(at: sourceURL),
          let resultingURL, resultingURL.isFileURL else { return false }
    let trash = folderLocationComponents(root)
    let result = folderLocationComponents(resultingURL)
    return result.count > trash.count && result.starts(with: trash)
}

/// Volume and existence facts captured for a `FileManager.trashItem` result.
public struct TrashResultFacts: Equatable, Sendable {
    public let hasResultingURL: Bool
    public let itemExists: Bool
    public let volumeKey: VolumeKey?

    public init(hasResultingURL: Bool, itemExists: Bool, volumeKey: VolumeKey?) {
        self.hasResultingURL = hasResultingURL
        self.itemExists = itemExists
        self.volumeKey = volumeKey
    }
}

/// Pure validation over facts captured around the Trash operation.
public func validateTrashResult(sourceVolumeKey: VolumeKey?,
                                result: TrashResultFacts) -> Bool {
    guard result.hasResultingURL,
          result.itemExists,
          let sourceVolumeKey,
          let resultVolumeKey = result.volumeKey else {
        return false
    }
    return sourceVolumeKey == resultVolumeKey
}

/// Probes the returned Trash URL and validates it against the source volume
/// key captured before moving the item.
public func validateTrashResult(sourceVolumeKey: VolumeKey,
                                resultingURL: URL?) -> Bool {
    guard let resultingURL else { return false }

    let exists = FileManager.default.fileExists(atPath: resultingURL.path)
    let resultVolume = probeVolume(at: resultingURL)
    return validateTrashResult(
        sourceVolumeKey: sourceVolumeKey,
        result: TrashResultFacts(hasResultingURL: true,
                                 itemExists: exists,
                                 volumeKey: resultVolume.volumeKey)
    )
}
