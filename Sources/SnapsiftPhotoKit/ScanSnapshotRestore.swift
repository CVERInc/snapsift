import Foundation
import SnapsiftCore

// Deterministic restore decisions, shared with the framework-free tests.
struct RestoredScanSnapshot {
    let groups: [ReviewGroup]
    let exactIDs: Set<ReviewGroup.ID>
    let categories: [CategoryBucket]
    let staleClearedSeeds: Int
    let vanishedMarks: Int
}

extension ScanSnapshot {
    func restored(liveFavorites: [String: Bool], editedNow: [String: Bool],
                         tokenCurrent: Bool) -> RestoredScanSnapshot {
        let snap = self
        var restoredGroups: [ReviewGroup] = []
        var exactIDs: Set<ReviewGroup.ID> = []
        // Count app-seeded suggestions dropped by the stale demotion so the UI can
        // stand up a persistent notice (a launch banner alone would fade unseen).
        var staleClearedSeeds = 0
        // Marks whose PHOTO no longer exists. They were silently compacted away
        // before: a user who marked 300 frames yesterday and lost 40 of them to
        // an external delete saw "restored N groups" and no hint that part of
        // their review work is gone. Counted here, surfaced by the view.
        var vanishedMarks = 0
        for gs in snap.groups {
            let liveIDs = Set(gs.photos.map(\.uuid).filter { liveFavorites[$0] != nil })
            vanishedMarks += Set(gs.rejected).subtracting(liveIDs).count
            let photos: [Photo] = gs.photos.compactMap { p in
                guard let favNow = liveFavorites[p.uuid] else { return nil }
                let editedLive = editedNow[p.uuid] ?? p.edited
                guard favNow != p.favorite || editedLive != p.edited else { return p }
                return p.with(favorite: favNow, edited: editedLive)
            }
            guard photos.count >= 2 else { continue }
            let keeperID = photos.contains { $0.uuid == gs.keeperID }
                ? gs.keeperID : keeper(photos).uuid
            var g = ReviewGroup(photos: photos, keeperID: keeperID)
            let alive = Set(photos.map(\.uuid))
            let protected = Set(photos.filter(\.isProtected).map(\.uuid))
            g.rejected = Set(gs.rejected).intersection(alive)
                .subtracting([keeperID])
                .subtracting(protected)   // protection re-applies on restore
            g.autoSeeded = Set(gs.autoSeeded).intersection(g.rejected)
            if !tokenCurrent {
                staleClearedSeeds += g.autoSeeded.count
                g.rejected.subtract(g.autoSeeded)   // stale app suggestions die
                g.autoSeeded = []
            }
            g.confidentDupe = gs.confidentDupe
            // includeProtected deliberately not restored (informed-consent flag).
            if gs.exact && tokenCurrent { exactIDs.insert(g.id) }
            restoredGroups.append(g)
        }
        let restoredCats = snap.categories.compactMap { cs -> CategoryBucket? in
            let photos = cs.photos.filter { liveFavorites[$0.uuid] != nil }
            return photos.count >= 2 ? CategoryBucket(label: cs.label, photos: photos) : nil
        }
        return RestoredScanSnapshot(groups: restoredGroups, exactIDs: exactIDs,
                                    categories: restoredCats, staleClearedSeeds: staleClearedSeeds,
                                    vanishedMarks: vanishedMarks)
    }
}
