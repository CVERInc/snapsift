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
}

// MARK: - AlbumWriter

/// Writes scan results into named Photos albums (strictly non-destructive — only
/// `PHAssetCollectionChangeRequest` create/add, never delete).
///
/// Philosophy: "Surface into albums, don't judge."
/// - The user browses candidates in their own time via the standard Photos UI
///   (or snapsift's keyboard UI via slice 2's album-input — the album names
///   round-trip cleanly since they are plain user-album titles).
/// - Adding an asset to a collection is membership-only: the original stays in
///   its existing location. Nothing is moved or removed.
/// - Idempotent: each call resolves the album by title (creating if absent),
///   fetches current members, and only adds assets NOT already present.
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
    /// `t`           — localization tokens.
    @discardableResult
    static func write(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>,
        assetsByID: [String: PHAsset],
        t: L10n
    ) async throws -> AlbumWriteResult {
        var result = AlbumWriteResult()

        // Gather the assets for each bucket. Computed synchronously before the
        // performChanges block — PHAsset is not Sendable through the closure.
        let burstsIDs   = burstCandidates(groups: groups, exactGroups: exactGroups)
        let blurryIDs   = blurryCandidates(groups: groups, exactGroups: exactGroups)
        let docsIDs     = documentCandidates(groups: groups)
        let exactIDs    = exactCandidates(groups: groups, exactGroups: exactGroups)

        let burstsAssets  = burstsIDs.compactMap  { assetsByID[$0] }
        let blurryAssets  = blurryIDs.compactMap  { assetsByID[$0] }
        let docsAssets    = docsIDs.compactMap    { assetsByID[$0] }
        let exactAssets   = exactIDs.compactMap   { assetsByID[$0] }

        // Each performChanges block is atomic per album — one block per album
        // keeps the operations small and lets PhotoKit interleave UI updates.
        if !burstsAssets.isEmpty {
            result.bursts = try await addAssets(burstsAssets,
                                                toAlbumNamed: albumBursts(t))
        }
        if !blurryAssets.isEmpty {
            result.blurry = try await addAssets(blurryAssets,
                                                toAlbumNamed: albumBlurry(t))
        }
        if !docsAssets.isEmpty {
            result.documents = try await addAssets(docsAssets,
                                                   toAlbumNamed: albumDocs(t))
        }
        if !exactAssets.isEmpty {
            result.exactDupes = try await addAssets(exactAssets,
                                                    toAlbumNamed: albumExact(t))
        }
        return result
    }

    // MARK: - Bucket selectors

    /// Non-keeper frames from non-exact groups → review bucket (not delete).
    /// Protected frames are excluded: they should never appear to be "candidates".
    private static func burstCandidates(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>
    ) -> [String] {
        groups
            .filter { !exactGroups.contains($0.id) }
            .flatMap { g in
                g.photos.filter { p in
                    !g.isKeeper(p) && !p.isProtected
                }.map(\.uuid)
            }
    }

    /// Blurry non-keepers: only frames in a real multi-photo cluster that rank
    /// lowest on sharpness AND are not the keeper. A lone photo is never "blurry".
    /// Protected frames are excluded.
    private static func blurryCandidates(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>
    ) -> [String] {
        groups
            .filter { $0.photos.count >= 2 && !exactGroups.contains($0.id) }
            .flatMap { g -> [String] in
                // Among the non-keepers, find those whose sharpness is strictly
                // below the keeper's. This is consistent with the Core ranking:
                // sharpness is a within-group signal, and "blurry" only means
                // "less sharp than the best frame we kept".
                guard let keepPhoto = g.photos.first(where: { $0.uuid == g.keeperID }) else {
                    return []
                }
                return g.photos.filter { p in
                    !g.isKeeper(p)
                        && !p.isProtected
                        && p.sharpness < keepPhoto.sharpness
                }.map(\.uuid)
            }
    }

    /// Document/ID/scan frames across ALL groups — organizational, not delete.
    /// Protected is already implied (isDocument → isProtected) but we include
    /// them here to surface them as the organizational bucket they are.
    private static func documentCandidates(groups: [ReviewGroup]) -> [String] {
        groups
            .flatMap(\.photos)
            .filter(\.isDocument)
            .map(\.uuid)
    }

    /// Non-keeper, non-protected frames from exact-duplicate groups only.
    /// This is the ONLY set that earns a delete suggestion in the UI.
    /// Honors the group's ACTUAL keeperID (user promotion / face refine) —
    /// re-deriving via Core's keeper() here could route the user's chosen
    /// keeper into the suggest-delete album while sparing the ranked frame.
    private static func exactCandidates(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>
    ) -> [String] {
        groups
            .filter { exactGroups.contains($0.id) }
            .flatMap { g in
                g.photos
                    .filter { $0.uuid != g.keeperID && !$0.isProtected }
                    .map(\.uuid)
            }
    }

    // MARK: - PhotoKit helpers (idempotent add)

    /// Resolve or create a user album by title, then add only assets NOT already
    /// present. Returns the number of assets actually added (0 on re-run).
    ///
    /// Idempotency: we fetch the album's current members, diff against the
    /// incoming set, and only add the newcomers. This means re-running the scan
    /// and clicking "Sort into albums" again is always safe — no duplicate
    /// membership, no error.
    @discardableResult
    private static func addAssets(_ assets: [PHAsset],
                                  toAlbumNamed name: String) async throws -> Int {
        // Step 1: resolve (or create) the album — read-only fetch first to
        // avoid an unnecessary write transaction.
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular,
            options: {
                let o = PHFetchOptions()
                o.predicate = NSPredicate(format: "localizedTitle == %@", name)
                return o
            }()
        )

        // Step 2: diff against current members so we never double-add.
        // Compute the set of ids we want to add before entering performChanges.
        var toAdd: [PHAsset] = []
        var collectionLocalID: String? = nil

        if let album = existing.firstObject {
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
