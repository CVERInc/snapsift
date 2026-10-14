import Foundation
import SnapsiftCore

/// Badge only observed Finder metadata; unknown facts withhold suggestions in
/// the folder pipeline but never justify claiming a tag/comment exists.
public func folderUniqueMetadataIDs(_ metadata: [String: LibraryMetadata]) -> Set<String> {
    Set(metadata.compactMap { $0.value.hasDescription == true ? $0.key : nil })
}

/// In-memory Folder Mode decisions. No persistence or Photos effects belong here.
public struct FolderReviewState {
    public var groups: [ReviewGroup]
    /// What the last ⇧K did to each group, so ⇧K again can put it back exactly
    /// (Core `keepOnlyUndoTarget`). In memory only, like the Photos session's.
    private var keepOnlyUndo: [ReviewGroup.ID: KeepOnlyUndo] = [:]

    public init(groups: [ReviewGroup] = []) { self.groups = groups }

    public enum Action {
        case promote(String)
        case keepOnly(String)
        case keepAll
        case toggleDeleteAll
        case toggleReject(String)
        case forceReject(String)
        case includeProtected(Bool)
    }

    /// Returns false when a frame is missing or its protection blocks marking.
    @discardableResult
    public mutating func apply(_ action: Action, to id: ReviewGroup.ID) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        if case .keepOnly(let frame) = action { return keepOnly(frame, in: id) != nil }
        var group = groups[index]
        switch action {
        case .promote(let frame):
            // The membership guard `PhotoLibrarySession.promote` gets from Core
            // `nominateAction`: a frame outside the group is never a keeper.
            guard group.photos.contains(where: { $0.uuid == frame }) else { return false }
            let next = promoteState(GroupMarkState(keeperID: group.keeperID, rejected: group.rejected), to: frame)
            group.autoSeeded.remove(frame)
            group.keeperID = next.keeperID
            group.rejected = next.rejected
        case .keepOnly:
            return false   // handled above
        case .keepAll:
            group.rejected = []
            group.autoSeeded = []
            group.includeProtected = false
        case .toggleDeleteAll:
            if group.deleteAll {
                group.rejected = []
                group.includeProtected = false
            } else {
                group.rejected = bulkRejectCandidates(photos: group.photos, keeperID: group.keeperID)
            }
            group.autoSeeded = []
        case .toggleReject(let frame):
            guard let photo = group.photos.first(where: { $0.uuid == frame }) else { return false }
            if group.rejected.contains(frame) {
                group.rejected.remove(frame)
                group.autoSeeded.remove(frame)
            } else {
                guard photo.isDeletable else { return false }
                group.rejected.insert(frame)
            }
            nominateSurvivor(in: &group)
        case .forceReject(let frame):
            guard let photo = group.photos.first(where: { $0.uuid == frame }), !photo.isUnverifiable else {
                return false
            }
            group.rejected.insert(frame)
            group.autoSeeded.remove(frame)
            group.includeProtected = true
            nominateSurvivor(in: &group)
        case .includeProtected(let value):
            let protected = Set(group.photos.filter { $0.isProtected && !$0.isUnverifiable }.map(\.uuid))
            group.includeProtected = value
            if value { group.rejected.formUnion(protected.subtracting([group.keeperID])) }
            else { group.rejected.subtract(protected) }
            group.autoSeeded.subtract(protected)
        }
        if group.protectedDeletionCount == 0 { group.includeProtected = false }
        groups[index] = group
        return true
    }

    /// ⇧K through Core `keepOnlyAction`, the verb the Photos session runs:
    /// membership guard, provenance (seeded marks ⇧K leaves standing stay
    /// seeded), the override rule, and the undo — ⇧K again on the same frame
    /// with nothing touched in between puts the group back exactly as it was.
    /// nil = no such group or frame.
    @discardableResult
    public mutating func keepOnly(_ frame: String, in id: ReviewGroup.ID) -> KeepOnlyOutcome? {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return nil }
        let group = groups[index]
        let current = GroupMarkSnapshot(keeperID: group.keeperID, rejected: group.rejected,
                                        autoSeeded: group.autoSeeded,
                                        includeProtected: group.includeProtected)
        guard let outcome = keepOnlyAction(photos: group.photos, current: current,
                                           undo: keepOnlyUndo[id], frameID: frame) else { return nil }
        let live = Set(groups.map(\.id))
        keepOnlyUndo = keepOnlyUndo.filter { live.contains($0.key) }
        let next: GroupMarkSnapshot
        switch outcome {
        case .undone(let back):
            next = back
            keepOnlyUndo[id] = nil
        case .applied(let after, let remember):
            next = after
            keepOnlyUndo[id] = remember
        }
        groups[index].keeperID = next.keeperID
        groups[index].rejected = next.rejected
        groups[index].autoSeeded = next.autoSeeded
        groups[index].includeProtected = next.includeProtected
        return outcome
    }

    private func nominateSurvivor(in group: inout ReviewGroup) {
        guard group.rejected.contains(group.keeperID) else { return }
        if let next = group.photos.filter({ !group.rejected.contains($0.uuid) })
            .max(by: { rankKey($0) < rankKey($1) }) {
            group.keeperID = next.uuid
        }
    }
}

/// Cross-folder primary matches can include grouped files absent from the near
/// groups. Add only unassigned items, so review never presents an item twice.
/// Clear pipeline suggestions for every cross-folder item, including overlaps.
public func folderReviewGroups(_ groups: [ReviewGroup], photos: [Photo],
                               crossFolderMatches: [[String]]) -> [ReviewGroup] {
    let crossIDs = Set(crossFolderMatches.flatMap { $0 })
    var result = groups.map { original -> ReviewGroup in
        var group = original
        group.rejected.subtract(crossIDs)
        group.autoSeeded.subtract(crossIDs)
        return group
    }
    var assigned = Set(result.flatMap { $0.photos.map(\.uuid) })
    let byID = Dictionary(photos.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
    for ids in crossFolderMatches {
        let remaining = ids.filter { !assigned.contains($0) }.compactMap { byID[$0] }
        // A singleton still needs a visible review card when its twin already
        // belongs to another group. These are informational, never seeded.
        if !remaining.isEmpty {
            result.append(ReviewGroup(photos: remaining, keeperID: keeper(remaining).uuid))
            assigned.formUnion(remaining.map(\.uuid))
        }
    }
    return result
}
