import Foundation

enum RotationSaveError: LocalizedError {
    case noEditingInput
    case noSourceImage
    case renderFailed
    case photoKitWriteFailed(Error)
    /// The frame already carries the user's own adjustments. Saving would flatten
    /// them (see `saveRotation`'s note on `canHandleAdjustmentData`), so this path
    /// refuses rather than quietly rewriting someone's edit.
    case frameAlreadyEdited
    /// We could not READ whether the frame carries adjustments — no Full Disk
    /// Access, the library the sidecar reads could not be confirmed, or the
    /// per-asset PhotoKit fallback timed out. Unknown ⇒ protected: this is the
    /// app's only path that rewrites a photo, so it is the last place that may
    /// act on a guess.
    case frameEditStateUnknown

    var errorDescription: String? {
        switch self {
        case .noEditingInput:
            return "Couldn't get editing access to this photo. Try again, or check that snapsift has Full Photos access."
        case .noSourceImage:
            return "Couldn't load the full-size original. The photo may still be downloading from iCloud."
        case .renderFailed:
            return "Couldn't render the rotated image."
        case .photoKitWriteFailed(let underlying):
            return "Photos couldn't save the rotation: \(underlying.localizedDescription)"
        case .frameAlreadyEdited:
            return "This photo already has edits. Saving a rotation would flatten them into a new version, so snapsift won't — rotate it in Photos instead."
        case .frameEditStateUnknown:
            return "snapsift can't tell whether this photo has edits right now, and saving a rotation would flatten any it does have. Rotate it in Photos instead."
        }
    }
}

