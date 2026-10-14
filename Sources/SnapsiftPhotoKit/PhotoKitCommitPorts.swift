import Foundation
import Photos
import SnapsiftCore

/// PhotoKit effects for the shared commit orchestration. The app injects its
/// current edited-state provider, including the macOS Photos.sqlite sidecar.
@MainActor
public enum PhotoKitCommitPorts {
    public static func make(
        storage: PhotoLibraryStorage = .init(directory: DeletionAuditLog.directory),
        editedNow: @escaping @MainActor ([(uuid: String, item: PHAsset)]) async -> [String: Bool]
    ) -> CommitPorts<PHAsset, DeletionSession> {
        // The journal may already hold an earlier, unreconciled commit
        // (deferred for lack of Photos access, or its history write failed).
        // `writeIntent` merges into it, and finishing THIS commit settles only
        // the records it wrote — never the whole file.
        let written = JournalWritten()
        return CommitPorts<PHAsset, DeletionSession>(
            fetchLive: { ids in
                // Match scan/restore: burst sub-frames must resolve by identifier.
                let opts = PHFetchOptions()
                opts.includeAllBurstAssets = true
                let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: opts)
                var live: [String: PHAsset] = [:]
                live.reserveCapacity(fetched.count)
                fetched.enumerateObjects { a, _, _ in live[a.localIdentifier] = a }
                return live
            },
            editedNow: editedNow,
            favoriteNow: { $0.isFavorite },
            burstSiblings: { asset in
                guard asset.representsBurst, let bid = asset.burstIdentifier else { return nil }
                let opts = PHFetchOptions()
                opts.includeAllBurstAssets = true
                let fetched = PHAsset.fetchAssets(withBurstIdentifier: bid, options: opts)
                var ids: [String] = []
                fetched.enumerateObjects { sibling, _, _ in ids.append(sibling.localIdentifier) }
                return ids
            },
            makeJournalEntry: { DeletionSession(timestamp: $0, records: $1) },
            writeIntent: { entry in
                guard DeletionAuditLog.writeIntent(entry, to: storage.journalURL) else { return false }
                written.entry = entry
                return true
            },
            delete: { assets in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
            },
            appendAudit: { DeletionAuditLog.append($0, to: storage.historyURL) },
            clearIntent: {
                // Nothing written by this commit ⇒ nothing of ours to settle;
                // an earlier journal stays for `reconcileDeletionJournal`.
                guard let entry = written.entry else { return }
                DeletionAuditLog.settleIntent(entry, at: storage.journalURL)
                written.entry = nil
            })
    }
}

/// The intent one commit wrote, so finishing that commit settles exactly it.
private final class JournalWritten {
    var entry: DeletionSession?
}
