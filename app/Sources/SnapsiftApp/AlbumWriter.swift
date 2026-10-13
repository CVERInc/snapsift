import Foundation
import Photos
import SnapsiftCore

// MARK: - Album-write result

/// How many assets were added to each Snapsift album in one write pass.
struct AlbumWriteResult {
    var bursts: Int = 0
    var blurry: Int = 0
    var documents: Int = 0
    var exactDupes: Int = 0
    /// Frames whose protection could not be determined at all (`Photo
    /// .isUnverifiable`), plus videos excluded from the scan because their
    /// Live Photo pairing was undetermined. Never a delete bucket — the human
    /// decides in Photos.app (ruling, chodaict, 2026-09-16).
    var needsLook: Int = 0
    /// Album memberships REMOVED from snapsift's own albums: frames THIS scan
    /// re-evaluated and no longer puts there (it became the keeper, was starred
    /// or edited, its group stopped being an exact duplicate, it moved to the
    /// other bucket). Never a frame the scan did not look at. One per album.
    /// Membership-only; no photo is ever deleted (see `removeAssets`).
    var moved: Int = 0
    /// Photos that were ALREADY in a Snapsift-titled album this sort adopted
    /// by title (Core `albumWasAdoptedNonEmpty`): not in the ledger, so never
    /// taken out automatically. Non-zero on the adopting sort only.
    var adoptedExisting: Int = 0
}

// MARK: - AlbumWriter

/// Writes scan results into named Photos albums (strictly non-destructive —
/// `PHAssetCollectionChangeRequest` create/add, plus membership REMOVAL from
/// snapsift's own albums; never `PHAssetChangeRequest.deleteAssets`, and never
/// any change at all to an album the user made).
///
/// Philosophy: "Surface into albums, don't judge."
/// - The user browses candidates in their own time via the standard Photos UI
///   (or snapsift's keyboard UI via slice 2's album-input — the album names
///   round-trip cleanly since they are plain user-album titles).
/// - Adding an asset to a collection is membership-only: the original stays in
///   its existing location. Nothing is moved or removed.
/// - Idempotent: each call resolves the album by title (creating if absent),
///   fetches current members, and only adds assets NOT already present.
/// - Authoritative over what the scan looked at: a current member this scan
///   re-evaluated and no longer puts there is taken out; members the scan
///   never saw are left alone (Core `albumSortPlan`).
///
/// The ONLY bucket where a delete suggestion is ever shown in the UI is
/// `exactDupes` — see Part B in LibraryModel. All other buckets are for
/// human review, explicitly not labeled as "delete".
enum AlbumWriter {

    // MARK: - Album name constants

    /// All snapsift albums share this prefix so they are easy to identify and
    /// round-trip correctly back into slice 2's album-input source picker.
    static let prefix = "Snapsift · "

    /// Localized album title for the bursts / near-duplicates review bucket.
    /// NOT a delete bucket — candidates for the user to review.
    static func albumBursts(_ t: L10n) -> String  { prefix + t.albumNameBursts() }
    /// Localized album title for frames that appear blurry relative to their
    /// cluster partner. Only members of a real multi-photo cluster, never lone
    /// photos. NOT a delete bucket.
    static func albumBlurry(_ t: L10n) -> String  { prefix + t.albumNameBlurry() }
    /// Localized album title for frames flagged as documents/IDs/receipts.
    /// Organizational only — explicitly NOT a delete bucket.
    static func albumDocs(_ t: L10n) -> String    { prefix + t.albumNameDocs() }
    /// Localized album title for frames that meet the strict exact-duplicate
    /// bar (dHash distance 0 + feature-print ≈0 + same dimensions). This is
    /// the ONLY album whose non-keeper, non-protected members the UI may badge
    /// as "可安心清 / safe to remove".
    static func albumExact(_ t: L10n) -> String   { prefix + t.albumNameExact() }
    /// Localized album title for frames snapsift could NOT classify at all —
    /// edit state unreadable, document eval ran blind, or (for a video) Live
    /// Photo pairing undetermined. NEVER a delete bucket, and unlike the other
    /// four buckets it is not even a REVIEW-for-deletion bucket: per doctrine
    /// (ruling, chodaict, 2026-09-16) these frames are never candidates —
    /// they are collected here strictly so the human can decide in Photos.app.
    static func albumNeedsLook(_ t: L10n) -> String { prefix + t.albumNameNeedsLook() }

    /// Every language's title for a bucket. Album resolution matches ANY of these
    /// so flipping the UI language between sorts resolves the album the user
    /// already has instead of spawning a duplicate parallel set — the localized
    /// title alone can't be the idempotency key. Creation still uses the active
    /// language's title (passed separately as `name`).
    static func allTitles(_ suffix: (L10n) -> String) -> [String] {
        Language.allCases.map { prefix + suffix(L10n($0)) }
    }

    /// Titles an EARLIER snapsift gave this same bucket, before the 2026-09-16
    /// rename (ruling, chodaict). They are NOT dead history: a dogfooded library
    /// already has albums under these names, and every place that resolves the
    /// bucket has to keep recognising them — otherwise the next sort creates a
    /// second, parallel album beside the one the user has been using, and
    /// reconcile stops seeing the frames already filed there.
    ///
    /// Retired names only ever get appended here; nothing is removed.
    static let legacyNeedsLookTitles: [String] = [
        prefix + "Needs a look",   // en-US, until 2026-09-16
        prefix + "請你看看",        // zh-TW, until 2026-09-16
        // ja-JP 「要確認」 was not renamed, so it needs no legacy entry.
    ]

    /// Every title this bucket answers to: the current one in each language,
    /// plus the retired ones. Album RESOLUTION uses this; album CREATION still
    /// uses the active language's current title.
    static var allNeedsLookTitles: [String] {
        allTitles { $0.albumNameNeedsLook() } + legacyNeedsLookTitles
    }

    /// Every title ANY snapsift build has ever created or could create, across
    /// every bucket and every language — used to exclude the tool's OWN
    /// organizational albums from signals that must reflect only the USER's
    /// library state (see `DeleteDecision.userAlbumCount`, used by
    /// `LibraryModel.libraryMetadata(for:)`).
    static var allSnapsiftTitles: Set<String> {
        Set(allTitles { $0.albumNameBursts() }
            + allTitles { $0.albumNameBlurry() }
            + allTitles { $0.albumNameDocs() }
            + allTitles { $0.albumNameExact() }
            + allNeedsLookTitles)
    }

    // MARK: - Write

    /// Sort the scan result into Photos albums. Returns a summary of how many
    /// assets were written to each album (0 = already present or no candidates).
    ///
    /// Rules enforced here (belt AND suspenders — LibraryModel enforces them
    /// upstream too, but AlbumWriter is the last line):
    ///   - Protected frames (`Photo.isProtected`) are NEVER written into any
    ///     delete-oriented bucket. They may only appear in the documents album.
    ///   - The blurry bucket only receives frames that are non-keeper in a real
    ///     multi-photo cluster (never a lone photo).
    ///   - The exact-dupes album only receives frames from groups that actually
    ///     passed the strict exact-duplicate predicate.
    ///   - All other groups go to the bursts album (for review, not for deletion).
    ///
    /// `groups`      — ReviewGroups from the scan (burst / look-alike scan).
    /// `exactGroups` — subset of groups that passed ExactDuplicatePredicate.
    ///                 Pass `[]` when the current scan hasn't run the predicate.
    /// `assetsByID`  — live PHAsset lookup (same map LibraryModel keeps).
    /// `extraNeedsLookAssets` — assets that never became a `Photo` at all (Live
    ///                 Photo paired-video undetermined) but are just as
    ///                 unclassifiable; folded into the same needs-look album.
    /// `ledger`      — what snapsift itself filed, and in which album (Core
    ///                 `AlbumLedger`). Read to decide, updated step by step as
    ///                 the steps are performed; the caller persists it.
    /// `scanKind`    — the kind of scan that produced `groups`; decides which
    ///                 albums this sort may take anything OUT of (Core
    ///                 `scanKindFeeds`). nil ⇒ add only.
    /// `t`           — localization tokens.
    @discardableResult
    static func write(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>,
        assetsByID: [String: PHAsset],
        extraNeedsLookAssets: [PHAsset] = [],
        scanKind: AlbumScanKind?,
        ledger: inout AlbumLedger,
        t: L10n
    ) async throws -> AlbumWriteResult {
        var result = AlbumWriteResult()

        // Core `albumSortPlan` IS the sort: which frames belong in each album,
        // and which current members come out. Nothing below decides anything —
        // it finds the albums, answers Core's questions about the library, and
        // performs the steps in order.
        let extraIDs = extraNeedsLookAssets.map(\.localIdentifier)
        var extraByID: [String: PHAsset] = [:]
        for a in extraNeedsLookAssets { extraByID[a.localIdentifier] = a }
        let sortGroups = groups.map {
            AlbumSortGroup(photos: $0.photos, keeperID: $0.keeperID,
                           rejected: $0.rejected, includeProtected: $0.includeProtected,
                           isExact: exactGroups.contains($0.id))
        }

        // 1. Find each album. The ledger's recorded collection id first; only
        //    when there is none (or that album is gone) do we look by title —
        //    and Core then allows this sort to ADD to what we find, never to
        //    take anything out of it (`AlbumResolution.byTitle`).
        var albums: [AlbumBucket: PHAssetCollection] = [:]
        var resolutions: [AlbumBucket: AlbumResolution] = [:]
        var members: [AlbumBucket: Set<String>] = [:]
        for bucket in AlbumBucket.allCases {
            var recorded: PHAssetCollection?
            resolutions[bucket] = albumResolution(recordedID: ledger.album(bucket).collectionID) { id in
                recorded = regularAlbum(withID: id)
                return recorded != nil
            }
            let album = recorded ?? albumByTitle(titles(for: bucket), preferring: name(for: bucket, t))
            albums[bucket] = album
            let current = album.map(memberIDs(of:)) ?? []
            members[bucket] = current
            if albumWasAdoptedNonEmpty(resolution: resolutions[bucket] ?? .byTitle,
                                       albumExists: album != nil, memberCount: current.count) {
                result.adoptedExisting += current.count
            }
        }

        // 2. Which of the ids Core asks about still exist (exact keepers and
        //    the recorded twins of filed duplicates — never the whole library).
        let query = albumLivenessQuery(groups: sortGroups, ledger: ledger)
        let missing = query.subtracting(existingAssetIDs(among: query))

        let steps = albumSortPlan(
            groups: sortGroups,
            scanKind: scanKind,
            extraNeedsLookIDs: extraIDs,
            ledger: ledger,
            resolution: { resolutions[$0] ?? .byTitle },
            missingIDs: missing,
            currentMembers: { members[$0] ?? [] })

        // 3. One step per album; each performChanges block is atomic per album.
        //    Take out first, then add, so the final membership is the plan's.
        //    The ledger advances after each step that completed, so a failure
        //    half-way leaves a record of exactly what was done.
        for step in steps {
            let album = albums[step.bucket]
            let before = members[step.bucket] ?? []
            if let album, !step.remove.isEmpty {
                result.moved += try await removeAssets(ids: step.remove, from: album)
            }
            var collectionID = album?.localIdentifier
            let assets = step.add.compactMap { assetsByID[$0] ?? extraByID[$0] }
            if !assets.isEmpty {
                let outcome = try await addAssets(assets, to: album,
                                                  creatingNamed: name(for: step.bucket, t),
                                                  alreadyIn: before)
                collectionID = outcome.collectionID
                switch step.bucket {
                case .bursts:    result.bursts = outcome.added
                case .blurry:    result.blurry = outcome.added
                case .documents: result.documents = outcome.added
                case .exact:     result.exactDupes = outcome.added
                case .needsLook: result.needsLook = outcome.added
                }
            }
            ledger = albumLedger(ledger, applying: step,
                                 added: Set(assets.map(\.localIdentifier)),
                                 collectionID: collectionID,
                                 currentMembers: before)
        }
        return result
    }

    /// Every title this bucket's album answers to (resolution), and the title
    /// to create it under (active language). Exhaustive over Core `AlbumBucket`.
    private static func titles(for bucket: AlbumBucket) -> [String] {
        switch bucket {
        case .bursts:    return allTitles { $0.albumNameBursts() }
        case .blurry:    return allTitles { $0.albumNameBlurry() }
        case .documents: return allTitles { $0.albumNameDocs() }
        case .exact:     return allTitles { $0.albumNameExact() }
        case .needsLook: return allNeedsLookTitles
        }
    }
    private static func name(for bucket: AlbumBucket, _ t: L10n) -> String {
        switch bucket {
        case .bursts:    return albumBursts(t)
        case .blurry:    return albumBlurry(t)
        case .documents: return albumDocs(t)
        case .exact:     return albumExact(t)
        case .needsLook: return albumNeedsLook(t)
        }
    }

    // MARK: - PhotoKit helpers (finding albums; read-only)

    /// The regular user-library album with this `localIdentifier`, if it still
    /// exists. This is how a snapsift album is recognised: by the id recorded
    /// when snapsift created or adopted it — not by its name, so renaming it
    /// in Photos does not orphan it and a namesake is not mistaken for it.
    private static func regularAlbum(withID id: String) -> PHAssetCollection? {
        guard let col = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil).firstObject,
              col.assetCollectionType == .album,
              col.assetCollectionSubtype == .albumRegular else { return nil }
        return col
    }

    /// FALLBACK only, for an album the ledger has no record of: a regular
    /// album carrying one of snapsift's titles (any language, retired names
    /// too), current language preferred.
    ///
    /// A title proves nothing about who made the album or what is in it — the
    /// user may have an album of her own with the same name, and this WILL
    /// find it and read its members. That is why Core lets a title-found album
    /// be added to and never taken from, and why only ids the ledger recorded
    /// are ever removable. (This comment used to claim "a user album is never
    /// read here". It was false.)
    private static func albumByTitle(_ candidateTitles: [String],
                                     preferring name: String) -> PHAssetCollection? {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "localizedTitle IN %@", candidateTitles)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: o)
        var resolved: PHAssetCollection?
        existing.enumerateObjects { col, _, stop in
            if col.localizedTitle == name {
                resolved = col
                stop.pointee = true
            } else if resolved == nil {
                resolved = col
            }
        }
        return resolved
    }

    private static func memberIDs(of album: PHAssetCollection) -> Set<String> {
        var ids = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in
            ids.insert(a.localIdentifier)
        }
        return ids
    }

    /// Which of `ids` still exist in the library. Burst members and hidden
    /// photos DO exist (they would otherwise read as "the other copy is gone");
    /// photos in Recently Deleted do not come back from a default fetch.
    private static func existingAssetIDs(among ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let o = PHFetchOptions()
        o.includeAllBurstAssets = true
        o.includeHiddenAssets = true
        var found = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: o).enumerateObjects { a, _, _ in
            found.insert(a.localIdentifier)
        }
        return found
    }

    // MARK: - PhotoKit helpers (the two writes)

    /// Remove `ids` from ONE album — the one the ledger recorded. Returns how
    /// many memberships were removed.
    ///
    /// SAFETY, stated because this is the only removal in the app that is not a
    /// deletion: `PHAssetCollectionChangeRequest.removeAssets` removes
    /// MEMBERSHIP. The photo stays in the library, in every other album, in
    /// every smart album, and in iCloud; nothing goes to Recently Deleted.
    /// `ids` come from Core `albumSortPlan`, which only ever returns ids the
    /// ledger says snapsift filed in this album.
    @discardableResult
    private static func removeAssets(ids: Set<String>,
                                     from album: PHAssetCollection) async throws -> Int {
        var members: [PHAsset] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in
            if ids.contains(a.localIdentifier) { members.append(a) }
        }
        guard !members.isEmpty else { return 0 }
        let cid = album.localIdentifier
        let doomed = members
        try await PHPhotoLibrary.shared().performChanges {
            guard let col = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [cid], options: nil).firstObject,
                  let req = PHAssetCollectionChangeRequest(for: col) else { return }
            req.removeAssets(doomed as NSArray)
        }
        return members.count
    }

    /// Add `assets` to `album`, or to a new album called `name` when there is
    /// none. Skips ids in `alreadyIn`. Returns how many were added and the
    /// `localIdentifier` of the album used (nil only if there was no album and
    /// nothing to add, so none was created).
    private static func addAssets(_ assets: [PHAsset],
                                  to album: PHAssetCollection?,
                                  creatingNamed name: String,
                                  alreadyIn: Set<String>) async throws
        -> (added: Int, collectionID: String?) {
        let toAdd = assets.filter { !alreadyIn.contains($0.localIdentifier) }
        let existingID = album?.localIdentifier
        guard !toAdd.isEmpty else { return (0, existingID) }
        // A class box: the change block is @Sendable and runs later; a captured
        // `var` could not be written from it.
        final class Box: @unchecked Sendable { var id: String? }
        let created = Box()
        try await PHPhotoLibrary.shared().performChanges {
            let collection: PHAssetCollectionChangeRequest
            if let cid = existingID,
               let col = PHAssetCollection.fetchAssetCollections(
                   withLocalIdentifiers: [cid], options: nil).firstObject,
               let req = PHAssetCollectionChangeRequest(for: col) {
                collection = req
            } else {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: name)
                created.id = req.placeholderForCreatedAssetCollection.localIdentifier
                collection = req
            }
            collection.addAssets(toAdd as NSArray)
        }
        return (toAdd.count, created.id ?? existingID)
    }
}
