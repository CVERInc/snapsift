import SnapsiftPhotoKit
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

extension PhotoLibraryProgress {
    func message(_ t: L10n) -> String {
        switch self {
        case .idle: return ""
        case .fetching: return t.progFetching()
        case .readingQuality: return t.progReadingQuality()
        case .writingAlbums: return t.progWritingAlbums()
        case .clustering(let count): return t.progClustering(count)
        case .hashing(let done, let total): return t.progHashing(done, total)
        case .confirming(let done, let total, let loaded): return t.progConfirming(done, total, loaded: loaded)
        case .skippedClusters(let count): return t.progSkippedClusters(count)
        case .verifying(let done, let total): return t.progVerifying(done, total)
        case .faces(let done, let total): return t.progFaces(done, total)
        case .naming(let done, let total): return t.progNaming(done, total)
        }
    }
}

extension PhotoLibraryNotice {
    func message(_ t: L10n) -> String {
        switch self {
        case .cancelled: return t.scanCancelled()
        case .albumGone: return t.progAlbumGone()
        case .restored(let count): return t.snapshotRestored(count)
        case .restoredStale: return t.snapshotRestoredStale()
        case .scanFinished(let count, let skipped):
            var message = count == 0 ? t.scanDoneNothing() : t.scanDoneBanner(count)
            if skipped > 0 { message += " " + t.scanPairedVideosSkipped(skipped) }
            return message
        }
    }
}
