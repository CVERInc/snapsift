import Foundation
import Photos
import SnapsiftCore

/// Public PhotoKit user-album membership plus the app's verified description
/// query. The macOS sidecar stays app-side; unreadable facts remain nil.
public struct PhotoKitMetadataProbe: UniqueMetadataProbe {
    private let asset: (String) -> PHAsset?
    private let snapsiftTitles: Set<String>
    private let descriptions: ([String]) async -> [String: Bool]?

    public init(asset: @escaping (String) -> PHAsset?, snapsiftTitles: Set<String>,
                descriptions: @escaping ([String]) async -> [String: Bool]?) {
        self.asset = asset
        self.snapsiftTitles = snapsiftTitles
        self.descriptions = descriptions
    }

    public func metadata(for uuids: [String]) async -> [String: LibraryMetadata] {
        guard !uuids.isEmpty else { return [:] }
        var albums: [String: Int] = [:]
        for id in uuids {
            guard let asset = asset(id) else { continue }
            // Through the lane: this is a synchronous PhotoKit call and a wedged
            // photolibraryd must strand one sacrificial thread, never the pool.
            // nil (timeout / breaker) stays nil — undetermined, not zero.
            if let n: Int = await PhotoKitSyncLane.call({
                let cols = PHAssetCollection.fetchAssetCollectionsContaining(
                    asset, with: .album, options: nil)
                var titles: [String] = []
                titles.reserveCapacity(cols.count)
                cols.enumerateObjects { col, _, _ in
                    titles.append(col.localizedTitle ?? "")
                }
                return userAlbumCount(titles: titles, snapsiftTitles: snapsiftTitles)
            }) {
                albums[id] = n
            }
        }
        let described = await descriptions(uuids)
        var out: [String: LibraryMetadata] = [:]
        for id in uuids {
            out[id] = LibraryMetadata(albumCount: albums[id], hasDescription: described?[id])
        }
        return out
    }
}
