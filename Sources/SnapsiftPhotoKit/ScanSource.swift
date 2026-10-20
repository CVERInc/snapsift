import Foundation
import Photos

// MARK: - AlbumItem

/// A Photos user album the user can choose as the scan's working set.
/// Carries only the metadata snapsift needs for the picker — no assets fetched
/// until the user actually triggers a scan.
public struct AlbumItem: Identifiable, Equatable {
    public init(id: String, title: String, estimatedCount: Int) {
        self.id = id; self.title = title; self.estimatedCount = estimatedCount
    }
    public let id: String          // PHAssetCollection.localIdentifier
    public let title: String
    public let estimatedCount: Int // PHAssetCollection.estimatedAssetCount (may be NSNotFound)
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
/// - `identifiers`: a fixed set of Photos local identifiers. Fetch order is
///   determined by the options, never by the order of the identifiers.
///
/// Every source can be combined with a separate optional capture-date bound.
///
/// Reading is strictly non-destructive: we only fetch membership of the
/// collection and never add, remove, or move assets.
public enum ScanSource: Equatable {
    case wholeLibrary
    case album(AlbumItem)
    case identifiers([String])

    public var displayTitle: String {
        switch self {
        case .wholeLibrary, .identifiers:
            return ""                         // callers use their own label
        case .album(let a): return a.title
        }
    }

    public var albumItem: AlbumItem? {
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
/// With no capture-date bound, caller options are passed through unchanged.
/// Otherwise the half-open bound (start inclusive, end exclusive) is added to
/// a copy for every source, preserving every caller filter and setting.
///
/// Returns `nil` for an unresolvable album or an empty identifier array; sessions
/// treat either as nothing to scan and preserve the previous review state.
func fetchAssets(source: ScanSource, captureDates: DateInterval? = nil,
                 options: PHFetchOptions) -> PHFetchResult<PHAsset>? {
    guard let request = ScanFetchRequest(source: source, captureDates: captureDates, options: options) else { return nil }
    switch request.source {
    case .wholeLibrary:
        return PHAsset.fetchAssets(with: request.options)

    case .album(let item):
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [item.id],
            options: nil
        )
        guard let collection = collections.firstObject else { return nil }
        return PHAsset.fetchAssets(in: collection, options: request.options)

    case .identifiers(let identifiers):
        return PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: request.options)
    }
}

/// Prepare every source's options without accessing Photos. An empty identifier
/// set is unavailable; a date bound that matches nothing is still a valid fetch.
struct ScanFetchRequest {
    let source: ScanSource
    let options: PHFetchOptions

    init?(source: ScanSource, captureDates: DateInterval?, options: PHFetchOptions) {
        if case .identifiers(let ids) = source, ids.isEmpty { return nil }
        self.source = source
        self.options = captureDates.map { captureDateFetchOptions(interval: $0, options: options) } ?? options
    }
}

/// Compose bounds without accessing Photos or mutating any caller-owned option.
func captureDateFetchOptions(interval: DateInterval, options: PHFetchOptions) -> PHFetchOptions {
    let scoped = options.copy() as! PHFetchOptions
    let bounds = NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                             interval.start as NSDate, interval.end as NSDate)
    let predicates = options.predicate.map { [$0, bounds] } ?? [bounds]
    scoped.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    return scoped
}

/// Count a source using the same filters as a scan, without enumerating assets.
/// Returns `nil` for an unresolvable album or an empty identifier array.
public func countAssets(source: ScanSource, captureDates: DateInterval? = nil, options: PHFetchOptions) -> Int? {
    fetchAssets(source: source, captureDates: captureDates, options: options)?.count
}
