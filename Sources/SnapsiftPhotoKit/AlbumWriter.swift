import Foundation
import Photos
import SnapsiftCore

// MARK: - Album-write result

/// How many assets were added to each Snapsift album in one write pass.
public struct AlbumWriteResult {
    public internal(set) var bursts: Int = 0
    public internal(set) var blurry: Int = 0
    public internal(set) var documents: Int = 0
    public internal(set) var exactDupes: Int = 0
    /// Frames whose protection could not be determined at all (`Photo
    /// .isUnverifiable`), plus videos excluded from the scan because their
    /// Live Photo pairing was undetermined. Never a delete bucket — the human
    /// decides in Photos.app (ruling, chodaict, 2026-09-16).
    public internal(set) var needsLook: Int = 0
    /// Frames REMOVED from the snapsift album they no longer belong to, because
    /// this scan classified them into the other one. Membership-only; no photo
    /// is ever deleted (see `removeAssets`).
    public internal(set) var moved: Int = 0
}

/// Outcome for one app-owned album in a write pass.
public enum AlbumWriteOutcome: Equatable, Sendable {
    /// This pass added this many memberships to the album.
    case added(Int)
    /// The pass had no new memberships to add (including already-present items).
    case nothingToAdd
    /// A PhotoKit operation for this album failed.
    case failed(String)
    /// A dependent operation was skipped to preserve reconciliation safety.
    case notAttempted
}

/// Per-album results from one Photos membership write pass.
public struct AlbumWriteReport: Equatable, Sendable {
    public internal(set) var bursts: AlbumWriteOutcome
    public internal(set) var blurry: AlbumWriteOutcome
    public internal(set) var documents: AlbumWriteOutcome
    public internal(set) var exactDupes: AlbumWriteOutcome
    public internal(set) var needsLook: AlbumWriteOutcome
    /// Memberships removed from the two reconciled albums.
    public internal(set) var moved: Int

    init(bursts: AlbumWriteOutcome = .notAttempted,
         blurry: AlbumWriteOutcome = .notAttempted,
         documents: AlbumWriteOutcome = .notAttempted,
         exactDupes: AlbumWriteOutcome = .notAttempted,
         needsLook: AlbumWriteOutcome = .notAttempted,
         moved: Int = 0) {
        self.bursts = bursts
        self.blurry = blurry
        self.documents = documents
        self.exactDupes = exactDupes
        self.needsLook = needsLook
        self.moved = moved
    }

    static var nothingToAdd: AlbumWriteReport {
        AlbumWriteReport(bursts: .nothingToAdd, blurry: .nothingToAdd,
                         documents: .nothingToAdd, exactDupes: .nothingToAdd,
                         needsLook: .nothingToAdd)
    }
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
///
/// The ONLY bucket where a delete suggestion is ever shown in the UI is
/// `exactDupes` — see Part B in LibraryModel. All other buckets are for
/// human review, explicitly not labeled as "delete".
enum AlbumWriter {

    /// Small PhotoKit boundary so write ordering and failure behavior can be
    /// exercised without a live Photos library.
    protocol Operations {
        func add(_ assetIDs: [String], toAlbumNamed name: String,
                 candidateTitles: [String]) async throws -> Int
        func remove(ids: Set<String>, fromAlbumTitles candidateTitles: [String]) async throws -> Int
    }

    private struct Plan {
        let bursts: [String]
        let blurry: [String]
        let documents: [String]
        let exactRemove: Set<String>
        let needsLookRemove: Set<String>
        let exactAdd: [String]
        let needsLookAdd: [String]
    }

    struct Execution {
        let report: AlbumWriteReport
        let error: Error?
    }

    private struct PhotoKitOperations: Operations {
        let assetsByID: [String: PHAsset]

        func add(_ assetIDs: [String], toAlbumNamed name: String,
                 candidateTitles: [String]) async throws -> Int {
            try await AlbumWriter.addAssets(assetIDs.compactMap { assetsByID[$0] },
                                            toAlbumNamed: name,
                                            candidateTitles: candidateTitles)
        }

        func remove(ids: Set<String>, fromAlbumTitles candidateTitles: [String]) async throws -> Int {
            try await AlbumWriter.removeAssets(ids: ids, fromAlbumTitles: candidateTitles)
        }
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
    /// `t`           — localization tokens.
    @discardableResult
    static func write(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>,
        assetsByID: [String: PHAsset],
        extraNeedsLookAssets: [PHAsset] = [],
        titles: PhotoLibraryAlbumTitles
    ) async throws -> AlbumWriteResult {
        let allAssets = photoKitAssets(assetsByID: assetsByID,
                                       extraNeedsLookAssets: extraNeedsLookAssets)
        let plan = makePlan(groups: groups, exactGroups: exactGroups,
                            availableAssetIDs: Set(allAssets.keys),
                            extraNeedsLookIDs: extraNeedsLookAssets.map(\.localIdentifier))
        let execution = await execute(plan, titles: titles,
                                      operations: PhotoKitOperations(assetsByID: allAssets),
                                      stopOnFailure: true)
        if let error = execution.error { throw error }
        return legacyResult(from: execution.report)
    }

    /// PhotoKit-backed report path used by `PhotoLibrarySession`.
    static func writeReport(
        groups: [ReviewGroup], exactGroups: Set<ReviewGroup.ID>,
        assetsByID: [String: PHAsset], extraNeedsLookAssets: [PHAsset] = [],
        titles: PhotoLibraryAlbumTitles
    ) async -> AlbumWriteReport {
        let allAssets = photoKitAssets(assetsByID: assetsByID,
                                       extraNeedsLookAssets: extraNeedsLookAssets)
        let plan = makePlan(groups: groups, exactGroups: exactGroups,
                            availableAssetIDs: Set(allAssets.keys),
                            extraNeedsLookIDs: extraNeedsLookAssets.map(\.localIdentifier))
        return await execute(plan, titles: titles,
                             operations: PhotoKitOperations(assetsByID: allAssets),
                             stopOnFailure: false).report
    }

    /// Run the same bucket plan with independent album outcomes. PhotoKit
    /// failures are captured in the report so other safe writes can proceed.
    static func writeReport(
        groups: [ReviewGroup], exactGroups: Set<ReviewGroup.ID>,
        availableAssetIDs: Set<String>, extraNeedsLookIDs: [String] = [],
        titles: PhotoLibraryAlbumTitles, operations: any Operations
    ) async -> AlbumWriteReport {
        let plan = makePlan(groups: groups, exactGroups: exactGroups,
                            availableAssetIDs: availableAssetIDs.union(extraNeedsLookIDs),
                            extraNeedsLookIDs: extraNeedsLookIDs)
        return await execute(plan, titles: titles, operations: operations,
                             stopOnFailure: false).report
    }

    /// Throwing test seam for the existing macOS-compatible fail-fast path.
    static func write(
        groups: [ReviewGroup], exactGroups: Set<ReviewGroup.ID>,
        availableAssetIDs: Set<String>, extraNeedsLookIDs: [String] = [],
        titles: PhotoLibraryAlbumTitles, operations: any Operations
    ) async throws -> AlbumWriteResult {
        let plan = makePlan(groups: groups, exactGroups: exactGroups,
                            availableAssetIDs: availableAssetIDs.union(extraNeedsLookIDs),
                            extraNeedsLookIDs: extraNeedsLookIDs)
        let execution = await execute(plan, titles: titles, operations: operations,
                                      stopOnFailure: true)
        if let error = execution.error { throw error }
        return legacyResult(from: execution.report)
    }

    private static func makePlan(groups: [ReviewGroup], exactGroups: Set<ReviewGroup.ID>,
                                 availableAssetIDs: Set<String>,
                                 extraNeedsLookIDs: [String]) -> Plan {
        let bursts = burstCandidates(groups: groups, exactGroups: exactGroups)
            .filter(availableAssetIDs.contains)
        let blurry = blurryCandidates(groups: groups, exactGroups: exactGroups)
            .filter(availableAssetIDs.contains)
        let documents = documentCandidates(groups: groups).filter(availableAssetIDs.contains)
        let exact = exactCandidates(groups: groups, exactGroups: exactGroups)
            .filter(availableAssetIDs.contains)
        var needsLook = needsLookCandidates(groups: groups)
            .filter(availableAssetIDs.contains)
        var seenNeedsLook = Set(needsLook)
        for id in extraNeedsLookIDs where availableAssetIDs.contains(id) && !seenNeedsLook.contains(id) {
            needsLook.append(id)
            seenNeedsLook.insert(id)
        }

        // The plan resolves overlap protectively: needs-a-look wins. Its two
        // removals must both finish before either reconciled album can be added.
        let buckets = albumBucketPlan(exactCandidates: exact, needsLookCandidates: needsLook)
        return Plan(bursts: bursts, blurry: blurry, documents: documents,
                    exactRemove: buckets.exactRemove,
                    needsLookRemove: buckets.needsLookRemove,
                    exactAdd: buckets.exactAdd,
                    needsLookAdd: buckets.needsLookAdd)
    }

    private static func photoKitAssets(assetsByID: [String: PHAsset],
                                       extraNeedsLookAssets: [PHAsset]) -> [String: PHAsset] {
        var assets: [String: PHAsset] = [:]
        for asset in assetsByID.values { assets[asset.localIdentifier] = asset }
        for asset in extraNeedsLookAssets { assets[asset.localIdentifier] = asset }
        return assets
    }

    private static func execute(_ plan: Plan, titles: PhotoLibraryAlbumTitles,
                                operations: any Operations,
                                stopOnFailure: Bool) async -> Execution {
        var report = AlbumWriteReport()

        func add(_ ids: [String], title: PhotoLibraryAlbumTitle) async -> Result<AlbumWriteOutcome, Error> {
            guard !ids.isEmpty else { return .success(.nothingToAdd) }
            do {
                let count = try await operations.add(ids, toAlbumNamed: title.name,
                                                     candidateTitles: title.candidateTitles)
                return .success(count > 0 ? .added(count) : .nothingToAdd)
            } catch {
                return .failure(error)
            }
        }

        func store(_ result: Result<AlbumWriteOutcome, Error>, in slot: inout AlbumWriteOutcome) -> Error? {
            switch result {
            case .success(let outcome): slot = outcome; return nil
            case .failure(let error): slot = .failed(error.localizedDescription); return error
            }
        }

        if let error = store(await add(plan.bursts, title: titles.bursts), in: &report.bursts), stopOnFailure {
            return Execution(report: report, error: error)
        }
        if let error = store(await add(plan.blurry, title: titles.blurry), in: &report.blurry), stopOnFailure {
            return Execution(report: report, error: error)
        }
        if let error = store(await add(plan.documents, title: titles.documents), in: &report.documents), stopOnFailure {
            return Execution(report: report, error: error)
        }

        // Reconciliation remains strict: exact removals happen first, then
        // needs-a-look removals, and no add occurs until both phases succeed.
        do {
            if !plan.exactRemove.isEmpty {
                report.moved += try await operations.remove(ids: plan.exactRemove,
                                                            fromAlbumTitles: titles.exact.candidateTitles)
            }
        } catch {
            report.exactDupes = .failed(error.localizedDescription)
            return Execution(report: report, error: error)
        }
        do {
            if !plan.needsLookRemove.isEmpty {
                report.moved += try await operations.remove(ids: plan.needsLookRemove,
                                                            fromAlbumTitles: titles.needsLook.candidateTitles)
            }
        } catch {
            report.needsLook = .failed(error.localizedDescription)
            report.exactDupes = .notAttempted
            return Execution(report: report, error: error)
        }

        if let error = store(await add(plan.exactAdd, title: titles.exact), in: &report.exactDupes), stopOnFailure {
            return Execution(report: report, error: error)
        }
        if let error = store(await add(plan.needsLookAdd, title: titles.needsLook), in: &report.needsLook), stopOnFailure {
            return Execution(report: report, error: error)
        }
        return Execution(report: report, error: nil)
    }

    private static func legacyResult(from report: AlbumWriteReport) -> AlbumWriteResult {
        func count(_ outcome: AlbumWriteOutcome) -> Int {
            if case .added(let value) = outcome { return value }
            return 0
        }
        var result = AlbumWriteResult()
        result.bursts = count(report.bursts)
        result.blurry = count(report.blurry)
        result.documents = count(report.documents)
        result.exactDupes = count(report.exactDupes)
        result.needsLook = count(report.needsLook)
        result.moved = report.moved
        return result
    }

    // MARK: - Bucket selectors

    /// Non-keeper frames from non-exact groups → review bucket (not delete).
    /// Protected frames are excluded: they should never appear to be "candidates".
    static func burstCandidates(
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
    static func blurryCandidates(
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
    static func documentCandidates(groups: [ReviewGroup]) -> [String] {
        groups
            .flatMap(\.photos)
            .filter(\.isDocument)
            .map(\.uuid)
    }

    /// Non-keeper, deletable frames from exact-duplicate groups only. This is
    /// the ONLY set that earns a delete suggestion in the UI, so it must use
    /// the SAME predicate the delete pipeline uses (`Photo.isDeletable` =
    /// not protected AND not unverifiable) — filtering `!isProtected` alone
    /// let a documentEvalDegraded / editedUndetermined frame into the album
    /// Photos.app shows as "safe to remove", even though snapsift's own
    /// delete pipeline would never touch it. Honors the group's ACTUAL
    /// keeperID (user promotion / face refine) — re-deriving via Core's
    /// keeper() here could route the user's chosen keeper into the
    /// suggest-delete album while sparing the ranked frame.
    static func exactCandidates(
        groups: [ReviewGroup],
        exactGroups: Set<ReviewGroup.ID>
    ) -> [String] {
        groups
            .filter { exactGroups.contains($0.id) }
            .flatMap { g in
                g.photos
                    .filter { $0.uuid != g.keeperID && $0.isDeletable }
                    .map(\.uuid)
            }
    }

    /// Every frame whose protection could not be determined AT ALL —
    /// `Photo.isUnverifiable` (document eval ran blind, or edit state
    /// unreadable). Independent of every other bucket and of keeper/reject
    /// state: the point is not "this frame lost a delete vote", it is
    /// "snapsift could not read this frame", so it is included regardless of
    /// whether it happens to be a group's keeper. This bucket is ADDITIVE —
    /// an unverifiable non-keeper frame may also land in `burstCandidates` /
    /// `blurryCandidates` (organizational, never a delete suggestion, so no
    /// safety concern in the overlap) — and it is the ONLY bucket that
    /// exists purely to route the frame to a human, not to suggest anything
    /// about it: `exactCandidates` never contains it (excluded upstream by
    /// `isDeletable` before the exact-dup pass ever seeds), and
    /// `documentCandidates` only catches a CONFIRMED document, not a
    /// degraded eval.
    static func needsLookCandidates(groups: [ReviewGroup]) -> [String] {
        groups.flatMap(\.photos).filter(\.isUnverifiable).map(\.uuid)
    }

    // MARK: - PhotoKit helpers (idempotent add / bucket reconciliation)

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
