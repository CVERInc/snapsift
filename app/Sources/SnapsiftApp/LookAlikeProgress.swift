import SnapsiftVision

/// Localization stays in the app; the shared scanner reports structured counts.
extension LookAlikeScanner.Progress {
    func message(_ t: L10n) -> String {
        switch self {
        case .hashing(let done, let total): return t.progHashing(done, total)
        case .confirming(let done, let total, let loaded): return t.progConfirming(done, total, loaded: loaded)
        case .skippedClusters(let count): return t.progSkippedClusters(count)
        case .verifying(let done, let total): return t.progVerifying(done, total)
        }
    }
}
