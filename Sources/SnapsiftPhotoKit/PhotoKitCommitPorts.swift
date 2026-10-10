import Foundation
import Photos
import SnapsiftCore

/// PhotoKit effects for the shared commit orchestration. The app injects its
/// current edited-state provider, including the macOS Photos.sqlite sidecar.
@MainActor
public enum PhotoKitCommitPorts {
    public static func make(
        editedNow: @escaping @MainActor ([(uuid: String, item: PHAsset)]) async -> [String: Bool]
    ) -> CommitPorts<PHAsset, DeletionSession> {
        CommitPorts<PHAsset, DeletionSession>(
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
            writeIntent: { DeletionAuditLog.writeIntent($0) },
            delete: { assets in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets as NSArray)
                }
            },
            appendAudit: { DeletionAuditLog.append($0) },
            clearIntent: { DeletionAuditLog.clearIntent() })
    }
}
