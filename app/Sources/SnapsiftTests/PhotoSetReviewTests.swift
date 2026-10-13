import Foundation
import AppKit
import Photos
import SnapsiftCore
@testable import SnapsiftPhotoKit

// Similar sets reviewed as groups, driven through the session's own scan-flag
// and commit paths with substituted library effects: no Photos library is read,
// nothing is deleted, and no image is decoded.

private final class SetTestAsset: PHAsset, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id; super.init() }
    override var localIdentifier: String { id }
    override var isFavorite: Bool { false }
    override var representsBurst: Bool { false }
}

/// Every image request answers "no local thumbnail".
private final class NoImageManager: PHCachingImageManager, @unchecked Sendable {
    override func requestImage(for asset: PHAsset, targetSize: CGSize, contentMode: PHImageContentMode,
                               options: PHImageRequestOptions?,
                               resultHandler: @escaping (NSImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID {
        resultHandler(nil, nil)
        return 1
    }
}

/// Stands in for the macOS app's enrichment port (default macOS configuration).
@MainActor
private final class FakeEnrichmentPort: PhotoLibraryEnrichmentPort {
    var qualityAvailable: Bool { false }
    var libraryIdentity: LibraryIdentity { .unverified(.pathUnknown) }
    func loadEnrichment(assets: [PHAsset], shouldAbort: @escaping @Sendable () -> Bool) async {}
    func verifyLibraryIdentity(sample: [PHAsset]) async {}
    func discardCancelledLoad() {}
    func enrichment(for id: String) -> PhotoLibraryEnrichment? { nil }
    func assetMetadata(for asset: PHAsset) -> PhotoLibraryAssetMetadata { .init(filename: "", uti: "") }
    func editedFlags(for targets: [(uuid: String, asset: PHAsset)]) async -> [String: Bool]? { nil }
    func descriptions(for ids: [String]) async -> [String: Bool]? { nil }
    nonisolated func setName(tags: [String], language: String) async -> String? { nil }
}

/// Library facts the substituted effects read from any executor.
private final class LibraryFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var liveIDs: Set<String> = []
    private var edited: [String: Bool] = [:]
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var live: Set<String> {
        get { locked { liveIDs } }
        set { locked { liveIDs = newValue } }
    }
    var editedNow: [String: Bool] {
        get { locked { edited } }
        set { locked { edited = newValue } }
    }
    var fallbackCalls: [String] { locked { calls } }
    func fallback(_ id: String) -> Bool? { locked { calls.append(id); return edited[id] } }
}

@MainActor
private final class SetSessionFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapsift-set-review-\(UUID())")
    let storage: PhotoLibraryStorage
    let session: PhotoLibrarySession
    let facts = LibraryFacts()
    var deleted: [String] = []
    var deletingDuringDelete = false
    var reentryBlocked = false

    init(enrichment: (any PhotoLibraryEnrichmentPort)? = nil, ids: [String]) {
        storage = PhotoLibraryStorage(directory: root)
        let title = PhotoLibraryAlbumTitle(name: "fixture", candidateTitles: [])
        session = PhotoLibrarySession(storage: storage,
            albumTitles: .init(bursts: title, blurry: title, documents: title, exact: title, needsLook: title),
            enrichment: enrichment, imageManager: NoImageManager())
        let assets = Dictionary(uniqueKeysWithValues: ids.map { ($0, SetTestAsset($0) as PHAsset) })
        let facts = facts
        facts.live = Set(ids)
        session.photoKitImages = session.makeImageProvider(assetsByID: assets)
        var effects = session.effects
        effects.editedFallback = { asset in facts.fallback(asset.localIdentifier) }
        effects.liveIDs = { ids in Set(ids).intersection(facts.live) }
        effects.fetchAssets = { ids in assets.filter { ids.contains($0.key) } }
        effects.commitPorts = { [weak self] storage, edited in
            var ports = PhotoKitCommitPorts.make(storage: storage, editedNow: edited)
            ports.fetchLive = { ids in assets.filter { ids.contains($0.key) && facts.live.contains($0.key) } }
            ports.burstSiblings = { _ in nil }
            ports.delete = { items in
                guard let self else { return }
                self.deletingDuringDelete = self.session.isDeleting
                do {
                    _ = try await self.session.deleteReviewed(in: [])
                } catch CommitError.busy { self.reentryBlocked = true } catch {}
                self.deleted += items.map(\.localIdentifier)
                facts.live.subtract(items.map(\.localIdentifier))
            }
            return ports
        }
        session.effects = effects
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
func checkPhotoSetReview() async {
    print("Similar sets reviewed as groups")

    // Scan: set members get the per-member flag pass without an enrichment port.
    do {
        let f = SetSessionFixture(ids: ["U1", "U2", "U3"])
        defer { f.cleanup() }
        f.facts.editedNow = ["U1": false, "U2": true]   // U3: the lookup cannot answer
        let sets = [[ph(1, 0, editedUnknown: true), ph(2, 1, editedUnknown: true)],
                    [ph(3, 2, editedUnknown: true), ph(1, 0, editedUnknown: true)]]
        let flagged = await f.session.flagSetMembers(sets)
        let byID = Dictionary(flagged.flatMap { $0 }.map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        check(flagged.map { $0.map(\.uuid) } == [["U1", "U2"], ["U3", "U1"]],
              "set flags: sets keep their members and order")
        check(byID["U1"]?.editedUndetermined == false && byID["U1"]?.edited == false
              && byID["U2"]?.editedUndetermined == false && byID["U2"]?.edited == true,
              "set flags: untrusted sidecar resolves edited state through the per-asset fallback")
        check(byID["U3"]?.editedUndetermined == true,
              "set flags: an unanswered fallback leaves the photo undetermined (protected)")
        check(flagged.flatMap { $0 }.allSatisfy { $0.documentEvalDegraded && !$0.isDocument },
              "set flags: a document check without pixels is marked degraded, never clear")
        check(Set(f.facts.fallbackCalls) == ["U1", "U2", "U3"] && f.facts.fallbackCalls.count == 3,
              "set flags: each member is looked up once, as in group scans")
    }

    // Default macOS configuration: the set scan's members stay untouched.
    do {
        let port = FakeEnrichmentPort()
        let f = SetSessionFixture(enrichment: port, ids: ["U1", "U2"])
        defer { f.cleanup() }
        let sets = [[ph(1, 0, editedUnknown: true), ph(2, 1, editedUnknown: true)]]
        let flagged = await f.session.flagSetMembers(sets)
        check(flagged == sets && f.facts.fallbackCalls.isEmpty,
              "set flags: a session with an enrichment port leaves set members and cost unchanged")
    }

    // Commit given groups through the session: edited-now held back, journal,
    // History, category pruning and identity.
    do {
        let ids = ["U11", "U12", "U13", "U14", "U15"]
        let f = SetSessionFixture(ids: ids)
        defer { f.cleanup() }
        f.facts.editedNow = ["U12": false, "U14": false, "U15": true]
        let setA = CategoryBucket(label: "Set A", photos: [ph(11, 0), ph(12, 1)])
        let setB = CategoryBucket(label: "Set B", photos: [ph(13, 2), ph(14, 3), ph(15, 4)])
        f.session.categories = [setA, setB]
        var groupA = ReviewGroup(photos: setA.photos, keeperID: "U11")
        groupA.rejected = ["U12"]
        var groupB = ReviewGroup(photos: setB.photos, keeperID: "U13")
        groupB.rejected = ["U14", "U15"]
        let withdrawn = await f.session.withdrawnGroupIDs(for: [groupA, groupB])
        check(withdrawn.isEmpty, "set commit: withdrawal check passes when every survivor is live")

        var events: [String] = []
        var published: [ReviewGroup] = []
        let result = try await f.session.deleteReviewed(
            in: [groupA, groupB],
            onProtectedDropped: { events.append("protected:\($0)") },
            onUndeterminedSkipped: { events.append("undetermined:\($0)") },
            onGroupsChanged: { published = $0; events.append("groups") })
        check(result.deletedIDs == ["U12", "U14"] && f.deleted == ["U12", "U14"],
              "set commit: only the photos the user let go are removed")
        check(events == ["groups", "protected:1"],
              "set commit: the session's edited re-check holds back a photo edited since the scan")
        check(published.count == 2 && published[1].id == groupB.id
              && published[1].photos.first { $0.uuid == "U15" }?.edited == true
              && !published[1].rejected.contains("U15"),
              "set commit: swept groups are published with the new protection and without its mark")
        check(f.deletingDuringDelete && f.reentryBlocked && !f.session.isDeleting,
              "set commit: the session's busy gate holds during removal and is released after")
        check(result.groups.map(\.id) == [groupB.id]
              && result.groups[0].photos.map(\.uuid) == ["U13", "U15"]
              && result.groups[0].rejected.isEmpty && result.groups[0].keeperID == "U13",
              "set commit: returned groups keep their ids, drop removed photos and omit groups under two")
        check(f.session.categories.map(\.id) == [setB.id]
              && f.session.categories[0].photos.map(\.uuid) == ["U13", "U15"]
              && f.session.categories[0].photos[1].edited,
              "set commit: removed photos leave the sets, sets under two leave, new protection is kept")
        let history = f.session.history.loadSessions().flatMap { $0.records.map(\.assetIdentifier) }
        check(Set(history) == ["U12", "U14"] && DeletionAuditLog.pendingIntent(at: f.storage.journalURL) == nil
              && !f.session.lastDeleteAuditFailed,
              "set commit: removal is journaled, recorded in History and the intent cleared")
        check(Set(f.session.photoKitImages.assetsByID.keys) == ["U13", "U15"],
              "set commit: the image provider keeps the surviving set photos")

        // The survivor promised by a set is gone from the library.
        var groupC = ReviewGroup(photos: f.session.categories[0].photos, keeperID: "U15")
        groupC.rejected = ["U13"]
        f.facts.live.remove("U15")
        let gone = await f.session.withdrawnGroupIDs(for: [groupC, result.groups[0]])
        check(gone == [groupC.id: .keeperMissing],
              "set commit: withdrawal check covers given groups; unmarked groups are not checked")
        check(await f.session.withdrawnGroupIDs().isEmpty,
              "set commit: the session's own withdrawal check still covers only its groups")
    } catch { check(false, "set commit threw \(error)") }

    // The session's own commit is unchanged by the shared path.
    do {
        let f = SetSessionFixture(ids: ["U21", "U22", "U23", "U24"])
        defer { f.cleanup() }
        f.facts.editedNow = ["U22": false, "U23": true]
        var g = ReviewGroup(photos: [ph(21, 0), ph(22, 1), ph(23, 2), ph(24, 3)], keeperID: "U21")
        g.rejected = ["U22", "U23"]
        f.session.groups = [g]
        var protected = 0
        let n = try await f.session.deleteReviewed(onProtectedDropped: { protected = $0 })
        check(n == 1 && f.deleted == ["U22"] && protected == 1,
              "deleteReviewed: removes the marked photo and holds back one edited since the scan")
        let after = f.session.groups
        check(after.count == 1 && after[0].id != g.id
              && after[0].photos.map(\.uuid) == ["U21", "U23", "U24"]
              && after[0].photos[1].edited && after[0].rejected.isEmpty,
              "deleteReviewed: the session's groups are rebuilt as before, keeping new protection")
        check(f.session.categories.isEmpty
              && f.session.history.loadSessions().flatMap { $0.records.map(\.assetIdentifier) } == ["U22"],
              "deleteReviewed: History records the removal; no sets are invented")
    } catch { check(false, "deleteReviewed threw \(error)") }
}
