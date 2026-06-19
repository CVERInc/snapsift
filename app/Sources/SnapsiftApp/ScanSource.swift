import Foundation
import Photos

// MARK: - AlbumItem

/// A Photos user album the user can choose as the scan's working set.
/// Carries only the metadata snapsift needs for the picker — no assets fetched
/// until the user actually triggers a scan.
struct AlbumItem: Identifiable, Equatable {
    let id: String          // PHAssetCollection.localIdentifier
    let title: String
    let estimatedCount: Int // PHAssetCollection.estimatedAssetCount (may be NSNotFound)
}

// MARK: - ScanSource

/// Where the scan fetches its working set from.
///
/// - `wholeLibrary`: the current behaviour — `PHAsset.fetchAssets(with:)` over
///   the whole library with no collection filter. Default.
/// - `album(AlbumItem)`: scope the fetch to a single user album via
///   `PHAsset.fetchAssets(in:options:)`. Existing filters (hidden=excluded,
///   trashed=excluded, media-type predicate, sort) all still apply — the only
///   change is the collection boundary.
///
/// Reading is strictly non-destructive: we only fetch membership of the
/// collection and never add, remove, or move assets.
enum ScanSource: Equatable {
    case wholeLibrary
    case album(AlbumItem)

    var displayTitle: String {
        switch self {
        case .wholeLibrary: return ""           // callers use their own label
        case .album(let a): return a.title
        }
    }

    var albumItem: AlbumItem? {
        if case .album(let a) = self { return a }
        return nil
    }
}

// MARK: - Album enumeration

/// Enumerate the user's smart / smart-less album list from the Photos library.
/// Reads only album metadata (title, estimated count) — no assets, no pixels, no
/// network.  Hidden and shared albums are excluded: hidden assets never appear in
/// snapsift's scan anyway; shared albums contain assets you don't own and the
/// membership is managed by Photos, so scoping to them would be misleading.
///
/// Called once after authorization and cached in `LibraryModel.albums`.
func fetchUserAlbums() -> [AlbumItem] {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

    let result = PHAssetCollection.fetchAssetCollections(
        with: .album,
        subtype: .albumRegular,
        options: opts
    )

    var albums: [AlbumItem] = []
    result.enumerateObjects { collection, _, _ in
        guard let title = collection.localizedTitle, !title.isEmpty else { return }
        let count = collection.estimatedAssetCount
        // estimatedAssetCount can be NSNotFound (Int.max) when the system hasn't
        // cached it yet. We pass it through as-is; the UI guards on NSNotFound.
        albums.append(AlbumItem(
            id: collection.localIdentifier,
            title: title,
            estimatedCount: count == NSNotFound ? -1 : count
        ))
    }
    return albums
}

// MARK: - Scoped asset fetch

/// Build a `PHFetchResult<PHAsset>` for the given source and options.
///
/// For `.wholeLibrary` this is `PHAsset.fetchAssets(with:options:)` — identical
/// to the existing scan path.  For `.album(_)` it resolves the album and calls
/// `PHAsset.fetchAssets(in:options:)`, scoping the result to that collection.
///
/// The `options` object is built by the caller (with sort descriptors, media-
/// type predicate, `includeAllBurstAssets`, etc.) and passed through unchanged —
/// this function never adds or removes filters.  It is therefore impossible for
/// this layer to accidentally include hidden or trashed assets that the caller's
/// predicate already excludes.
///
/// Returns `nil` when the album can no longer be resolved (deleted between when
/// the picker showed it and when the scan ran) — callers must handle that as an
/// early-exit.
func fetchAssets(source: ScanSource, options: PHFetchOptions) -> PHFetchResult<PHAsset>? {
    switch source {
    case .wholeLibrary:
        return PHAsset.fetchAssets(with: options)

    case .album(let item):
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [item.id],
            options: nil
        )
        guard let collection = collections.firstObject else { return nil }
        return PHAsset.fetchAssets(in: collection, options: options)
    }
}
