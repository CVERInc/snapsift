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
    /// `scanScope` / `libraryIDs` — did that scan cover the whole library, and
    ///                 if so the ids it looked at (Core `albumWorkingSet`).
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
        scanScope: AlbumScanScope = .narrow,
        libraryIDs: () -> Set<String> = { [] },
        t: L10n
    ) async throws -> AlbumWriteResult {
        var result = AlbumWriteResult()

        // Core `albumSortPlan` IS the sort: which frames belong in each album,
        // and which current members come out. Nothing below decides anything —
        // it resolves ids to assets and performs the steps, in order.
        //
        // Removals are scoped to what THIS scan re-evaluated (review P1-1):
        // a member the scan never looked at — another scan kind's results, a
        // photo outside a narrow scan — stays where it is.
        let extraIDs = extraNeedsLookAssets.map(\.localIdentifier)
        var extraByID: [String: PHAsset] = [:]
        for a in extraNeedsLookAssets { extraByID[a.localIdentifier] = a }

        let steps = albumSortPlan(
            groups: groups.map {
                AlbumSortGroup(photos: $0.photos, keeperID: $0.keeperID,
                               rejected: $0.rejected, includeProtected: $0.includeProtected,
                               isExact: exactGroups.contains($0.id))
            },
            scanKind: scanKind,
            // Whole-library scan ⇒ Exact Duplicates is reconciled against every
            // asset that scan looked at (review P2-A); Core asks for the ids
            // only then.
            scanScope: scanScope,
            extraNeedsLookIDs: extraIDs,
            libraryIDs: libraryIDs,
            currentMembers: { currentMemberIDs(inAlbumTitles: titles(for: $0)) })

        // One step per album; each performChanges block is atomic per album.
        // Take out first, then add, so the final membership is the plan's.
        for step in steps {
            result.moved += try await removeAssets(ids: step.remove,
                                                   fromAlbumTitles: titles(for: step.bucket))
            let assets = step.add.compactMap { assetsByID[$0] ?? extraByID[$0] }
            guard !assets.isEmpty else { continue }
            let added = try await addAssets(assets,
                                            toAlbumNamed: name(for: step.bucket, t),
                                            candidateTitles: titles(for: step.bucket))
            switch step.bucket {
            case .bursts:    result.bursts = added
            case .blurry:    result.blurry = added
            case .documents: result.documents = added
            case .exact:     result.exactDupes = added
            case .needsLook: result.needsLook = added
            }
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

    // MARK: - PhotoKit helpers (idempotent add / bucket reconciliation)

    /// The ids currently in snapsift's OWN album(s) for one bucket — the
    /// `currentMembers` that Core `albumMembershipRemovals` reconciles against.
    ///
    /// Resolved exactly as `removeAssets` and `addAssets` resolve it: regular
    /// albums whose title is one of snapsift's own (`candidateTitles`, every
    /// language plus retired names). That title match is the whole guard — a
    /// user album is never read here, so it can never be reconciled; a snapsift
    /// album the user renamed is not found and is left alone. Read-only.
    private static func currentMemberIDs(inAlbumTitles candidateTitles: [String]) -> Set<String> {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "localizedTitle IN %@", candidateTitles)
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: o)
        var ids = Set<String>()
        albums.enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in
                ids.insert(a.localIdentifier)
            }
        }
        return ids
    }

    /// Remove `ids` from a snapsift-owned album, if that album exists and any of
    /// them are actually in it. Returns how many memberships were removed.
    ///
    /// SAFETY, stated because this is the only removal in the app that is not a
    /// deletion: `PHAssetCollectionChangeRequest.removeAssets` removes
    /// MEMBERSHIP. The photo stays in the library, in every other album, in
    /// every smart album, and in iCloud; nothing goes to Recently Deleted. The
    /// album is resolved ONLY by snapsift's own titles in every language
    /// (`candidateTitles`), exactly as `addAssets` resolves it — so a user album
    /// is never touched, and a snapsift album the user RENAMED is simply not
    /// found and nothing happens (the same degradation `addAssets` already has).
    /// If the album does not exist yet, this is a no-op: we never create an
    /// album in order to remove from it.
    @discardableResult
    private static func removeAssets(ids: Set<String>,
                                     fromAlbumTitles candidateTitles: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular,
            options: {
                let o = PHFetchOptions()
                o.predicate = NSPredicate(format: "localizedTitle IN %@", candidateTitles)
                return o
            }()
        )
        var removed = 0
        var albums: [PHAssetCollection] = []
        existing.enumerateObjects { col, _, _ in albums.append(col) }
        // Every matching album, not just the current language's: a user who
        // flipped languages can hold two, and leaving the stale one populated
        // would leave the contradiction this exists to end.
        for album in albums {
            var members: [PHAsset] = []
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in
                if ids.contains(a.localIdentifier) { members.append(a) }
            }
            guard !members.isEmpty else { continue }
            let cid = album.localIdentifier
            let doomed = members
            try await PHPhotoLibrary.shared().performChanges {
                guard let col = PHAssetCollection.fetchAssetCollections(
                        withLocalIdentifiers: [cid], options: nil).firstObject,
                      let req = PHAssetCollectionChangeRequest(for: col) else { return }
                req.removeAssets(doomed as NSArray)
            }
            removed += members.count
        }
        return removed
    }

    // MARK: - PhotoKit helpers (idempotent add)

    /// Resolve or create a user album by title, then add only assets NOT already
    /// present. Returns the number of assets actually added (0 on re-run).
    ///
    /// Idempotency: we fetch the album's current members, diff against the
    /// incoming set, and only add the newcomers. This means re-running the scan
    /// and clicking "Sort into albums" again is always safe — no duplicate
    /// membership, no error.
    ///
    /// `name`            — the album title to CREATE under if none exists (active language).
    /// `candidateTitles` — every language's title for this bucket; resolution
    ///                     matches any of them so a language flip doesn't duplicate.
    @discardableResult
    private static func addAssets(_ assets: [PHAsset],
                                  toAlbumNamed name: String,
                                  candidateTitles: [String]) async throws -> Int {
        // Step 1: resolve (or create) the album — read-only fetch first to
        // avoid an unnecessary write transaction. Match ANY language's title.
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular,
            options: {
                let o = PHFetchOptions()
                o.predicate = NSPredicate(format: "localizedTitle IN %@", candidateTitles)
                return o
            }()
        )

        // If the user accumulated several albums from earlier language flips,
        // prefer the current-language one; otherwise take the first match.
        var resolved: PHAssetCollection? = nil
        existing.enumerateObjects { col, _, stop in
            if col.localizedTitle == name {
                resolved = col
                stop.pointee = true
            } else if resolved == nil {
                resolved = col
            }
        }

        // Step 2: diff against current members so we never double-add.
        // Compute the set of ids we want to add before entering performChanges.
        var toAdd: [PHAsset] = []
        var collectionLocalID: String? = nil

        if let album = resolved {
            collectionLocalID = album.localIdentifier
            let memberResult = PHAsset.fetchAssets(in: album, options: nil)
            var memberIDs = Set<String>()
            memberResult.enumerateObjects { a, _, _ in memberIDs.insert(a.localIdentifier) }
            toAdd = assets.filter { !memberIDs.contains($0.localIdentifier) }
        } else {
            // Album doesn't exist yet — will be created in the change block.
            toAdd = assets
        }

        guard !toAdd.isEmpty else { return 0 }

        // Step 3: perform the write (create if needed, then add members).
        // `collectionLocalID` is captured to look up the created collection
        // inside the change block when we need to create a new album.
        var newCollectionID: String? = nil
        try await PHPhotoLibrary.shared().performChanges {
            let collection: PHAssetCollectionChangeRequest
            if let cid = collectionLocalID,
               let col = PHAssetCollection.fetchAssetCollections(
                   withLocalIdentifiers: [cid], options: nil).firstObject {
                collection = PHAssetCollectionChangeRequest(for: col)!
            } else {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: name)
                newCollectionID = req.placeholderForCreatedAssetCollection.localIdentifier
                collection = req
            }
            collection.addAssets(toAdd as NSArray)
        }
        _ = newCollectionID  // used implicitly via the change block capture
        return toAdd.count
    }
}
