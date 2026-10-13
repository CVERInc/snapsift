import Foundation

// MARK: - The filed ledger
//
// What snapsift itself put into each of its albums. Two failures made it
// necessary (review of PR #8, P1-1 and P2-1):
//
//   • An album was "ours" if its TITLE was one of ours. A user's own album
//     called "Exact Duplicates" was reconciled like any other, and a sort
//     could take her photos out of it.
//   • To notice "the other copy of this filed photo is gone", the working set
//     was widened to the whole library — on the premise that a whole-library
//     scan had checked every photo for duplicates. It had not: only photos
//     that landed in a group are ever hashed.
//
// The ledger answers both with a record instead of an inference: this album
// (by `PHAssetCollection.localIdentifier`), these ids, and — for Exact
// Duplicates — which photo each one was a duplicate OF.
//
// An id that is not in the ledger is never removed from anything, whatever the
// album is called. That includes every photo filed by a version of the app
// from before the ledger existed, and every photo that was already in an
// album when snapsift first found it: only an id snapsift ADDED is recorded,
// so those stay where they are for good (unless the user takes one out and a
// later sort puts it back — then snapsift did file it).

public struct AlbumLedger: Codable, Equatable {
    public struct Filed: Codable, Equatable {
        /// Exact Duplicates only: the keeper this photo was filed as a
        /// duplicate of. When that photo no longer exists, this one is the
        /// last copy and must not stay in an album labelled "safe to delete".
        public let twin: String?
        public init(twin: String? = nil) { self.twin = twin }
    }
    public struct Album: Codable, Equatable {
        /// `PHAssetCollection.localIdentifier` of the album snapsift created or
        /// adopted. nil = none recorded yet.
        public var collectionID: String?
        public var filed: [String: Filed]
        public init(collectionID: String? = nil, filed: [String: Filed] = [:]) {
            self.collectionID = collectionID
            self.filed = filed
        }
    }
    /// Keyed by `AlbumBucket.ledgerKey`.
    public var albums: [String: Album]
    public init(albums: [String: Album] = [:]) { self.albums = albums }

    public func album(_ bucket: AlbumBucket) -> Album { albums[bucket.ledgerKey] ?? Album() }
    public var allFiledIDs: Set<String> { Set(albums.values.flatMap { $0.filed.keys }) }
}

extension AlbumBucket {
    /// On-disk key. Pinned by the test suite: renaming one orphans that
    /// album's record (the safe direction — nothing is removed — but silent).
    public var ledgerKey: String {
        switch self {
        case .bursts:    return "bursts"
        case .blurry:    return "blurry"
        case .documents: return "documents"
        case .exact:     return "exact"
        case .needsLook: return "needsLook"
        }
    }
}

/// How this sort finds one of snapsift's albums.
public enum AlbumResolution: Equatable {
    /// The album the ledger recorded, and it still exists. The ONLY case in
    /// which anything may be taken out.
    case recorded(String)
    /// No record, or the recorded album is gone. The app may find an album by
    /// snapsift's titles or create one, and ADD to it; it removes nothing,
    /// because nothing proves the album found is the one snapsift filled.
    case byTitle
}

public func albumResolution(recordedID: String?, resolves: (String) -> Bool) -> AlbumResolution {
    guard let id = recordedID, resolves(id) else { return .byTitle }
    return .recorded(id)
}

/// The ids snapsift may take out of this album: the ones it filed there, and
/// only when the album is the recorded one.
public func ledgerFiledIDs(_ ledger: AlbumLedger, _ bucket: AlbumBucket,
                           _ resolution: AlbumResolution) -> Set<String> {
    let album = ledger.album(bucket)
    guard case .recorded(let id) = resolution, id == album.collectionID else { return [] }
    return Set(album.filed.keys)
}

/// The ids whose existence the sort needs to know: the keeper of every exact
/// group (a group whose keeper is gone proves nothing) and the recorded twin
/// of every filed exact duplicate. A handful to a few thousand — never the
/// library. (A FILED id that no longer exists is not asked about: it cannot be
/// a member of anything, so there is nothing to remove.)
public func albumLivenessQuery(groups: [AlbumSortGroup], ledger: AlbumLedger) -> Set<String> {
    var ids = Set(groups.filter(\.isExact).map(\.keeperID))
    ids.formUnion(ledger.album(.exact).filed.values.compactMap(\.twin))
    return ids
}

/// The ledger after one executed step. `collectionID` = the album the step was
/// performed on (nil if none exists and none was created). `currentMembers` =
/// that album's members BEFORE the step: a filed id the user has since taken
/// out by hand is forgotten, so putting it back by hand makes it hers.
/// `added` = the ids the writer could actually resolve to a photo and hand to
/// PhotoKit. NOT `step.add`: the plan may name an id that no longer resolves
/// (deleted since the scan), and recording that as "filed by us" would let a
/// later sort take out a photo the user put there herself (review P3-9).
public func albumLedger(_ ledger: AlbumLedger, applying step: AlbumStep,
                        added: Set<String>,
                        collectionID: String?, currentMembers: Set<String>) -> AlbumLedger {
    var album: AlbumLedger.Album
    switch step.resolution {
    case .recorded: album = ledger.album(step.bucket)
    case .byTitle:  album = AlbumLedger.Album()      // the old record described an album that is gone
    }
    if let collectionID { album.collectionID = collectionID }
    album.filed = album.filed.filter { currentMembers.contains($0.key) && !step.remove.contains($0.key) }
    // Recorded as filed: what this step ADDED (it was not a member before),
    // and what the record already held (its twin may have changed). An id
    // that was already in the album without a record is not ours to claim —
    // in an adopted namesake album that is every photo the user put there.
    // And nothing is recorded as filed in an album we cannot name.
    if album.collectionID != nil {
        for id in step.add where album.filed[id] != nil
            || (added.contains(id) && !currentMembers.contains(id)) {
            album.filed[id] = AlbumLedger.Filed(twin: step.twins[id])
        }
    }
    var out = ledger
    out.albums[step.bucket.ledgerKey] = album
    return out
}

/// Did this sort just ADOPT, by title, an album that already had photos in it?
///
/// Those photos are not in the ledger (an earlier version filed them, or the
/// user did), so snapsift will never take them out — and the album may be the
/// one labelled "safe to delete". That has to be said, once: the sort that
/// adopts records the album, every later sort resolves it as `.recorded`, and
/// this is false from then on.
public func albumWasAdoptedNonEmpty(resolution: AlbumResolution, albumExists: Bool,
                                    memberCount: Int) -> Bool {
    resolution == .byTitle && albumExists && memberCount > 0
}

// MARK: - Scan snapshot (the on-disk shape)

/// The last scan's review state as persisted across launches. Lives in Core so
/// the test suite decodes the real type: a snapshot that fails to decode is
/// every review decision gone.
public struct ScanSnapshot: Codable {
    /// Bump only on a breaking shape change (older files are then discarded).
    /// Optional additions — like `albumLedger` — do NOT bump it.
    public static let currentSchema = 1

    public struct Group: Codable {
        public let photos: [Photo]
        public let keeperID: String
        public let rejected: [String]
        public let autoSeeded: [String]
        public let confidentDupe: Bool
        public let exact: Bool
        public init(photos: [Photo], keeperID: String, rejected: [String], autoSeeded: [String],
                    confidentDupe: Bool, exact: Bool) {
            self.photos = photos; self.keeperID = keeperID; self.rejected = rejected
            self.autoSeeded = autoSeeded; self.confidentDupe = confidentDupe; self.exact = exact
        }
    }

    public struct Category: Codable {
        public let label: String
        public let photos: [Photo]
        public init(label: String, photos: [Photo]) { self.label = label; self.photos = photos }
    }

    public let schema: Int
    public let kind: String
    public let sourceID: String?
    public let timestamp: Date
    public let changeToken: Data?
    public let groups: [Group]
    public let categories: [Category]
    /// Optional: absent in files written before the ledger existed (synthesized
    /// Codable decodes a missing Optional as nil). Absent ⇒ an empty ledger ⇒
    /// nothing is ever removed from an album on its account.
    public let albumLedger: AlbumLedger?

    public init(schema: Int, kind: String, sourceID: String?, timestamp: Date, changeToken: Data?,
                groups: [Group], categories: [Category], albumLedger: AlbumLedger? = nil) {
        self.schema = schema; self.kind = kind; self.sourceID = sourceID
        self.timestamp = timestamp; self.changeToken = changeToken
        self.groups = groups; self.categories = categories; self.albumLedger = albumLedger
    }
}
