import Foundation
import SnapsiftCore
import SnapsiftFolder

public struct FolderRemovalReview: Identifiable {
    public let id = UUID()
    public let summary: FolderPreCommitSummary
    public let groups: [ReviewGroup]
    public init(summary: FolderPreCommitSummary, groups: [ReviewGroup]) {
        self.summary = summary
        self.groups = groups
    }
    public var protectedCount: Int {
        groups.reduce(0) { count, group in
            count + group.photos.filter { $0.isProtected && summary.eligibleItemIDs.contains($0.uuid) }.count
        }
    }
    public var noSurvivorCount: Int {
        noSurvivorGroupCount(groups.filter { !Set($0.deletionIDs).isDisjoint(with: summary.eligibleItemIDs) }
            .map { (photos: $0.photos, rejected: $0.rejected, includeProtected: $0.includeProtected) })
    }
}

/// One app-owned lock covers the pre-gate, shared commit and restore effects.
public struct FolderActivityState {
    public enum Operation: Equatable { case idle, reviewing, committing, puttingBack, reconciling }
    public private(set) var operation: Operation = .idle
    public init() {}
    public var isBusy: Bool { operation != .idle }

    @discardableResult public mutating func begin(_ next: Operation) -> Bool {
        guard next != .idle, !isBusy else { return false }
        operation = next
        return true
    }
    public mutating func finish() { operation = .idle }
}

extension FolderReviewState {
    /// Core owns survivor/keeper ranking. A failed singleton remains reviewable;
    /// an unmarked singleton is resolved just as it is in Photos Mode.
    public mutating func finishRemoval(removed: Set<String>, failed: Set<String>) {
        groups = groups.compactMap { group in
            guard group.photos.contains(where: { removed.contains($0.uuid) }) else { return group }
            let remaining = group.photos.filter { !removed.contains($0.uuid) }
            guard !remaining.isEmpty else { return nil }
            let regrouped = regroupAfterDeletion(photos: group.photos, keeperID: group.keeperID, removed: removed)
            guard regrouped != nil || remaining.contains(where: { failed.contains($0.uuid) }) else { return nil }
            var next = group
            next.photos = regrouped?.photos ?? remaining
            next.keeperID = regrouped?.keeperID ?? keeper(remaining).uuid
            next.rejected.formIntersection(remaining.map(\.uuid))
            next.autoSeeded.formIntersection(next.rejected)
            // Consent was not consumed for a protected item that failed to move.
            next.includeProtected = group.includeProtected && remaining.contains {
                failed.contains($0.uuid) && $0.isProtected && next.rejected.contains($0.uuid)
            }
            return next
        }
    }
}

public enum FolderHistoryUnavailableReason: CaseIterable {
    case volumeNotMounted, trashMissing, locationUnknown, itemChanged, cannotVerify
    case incompleteRemoval, restoring, restored
}

/// Presentation only: FolderHistoryStore.canPutBack remains the restore gate.
/// Ancestor probes distinguish an emptied Trash from an unmounted volume.
public func folderHistoryUnavailableReason(
    _ record: FolderHistoryRecord,
    volumeKey: (URL) -> VolumeKey? = { probeVolume(at: $0).volumeKey },
    readMember: (URL) -> FolderMember? = { try? FolderMember.read(at: $0) },
    pathExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
) -> FolderHistoryUnavailableReason {
    switch record.state {
    case .restored: return .restored
    case .restoring: return .restoring
    case .rollbackFailed, .pending: return .incompleteRemoval
    case .locationUnknown: return .locationUnknown
    case .removed, .trashMissing: break
    }
    func mounted(_ url: URL) -> Bool {
        var ancestor = url
        while true {
            if volumeKey(ancestor) == record.volumeKey { return true }
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { return false }
            ancestor = parent
        }
    }
    guard record.members.contains(where: { mounted($0.trashURL ?? $0.originalURL) || mounted($0.originalURL) })
    else { return .volumeNotMounted }
    if record.state == .trashMissing { return .trashMissing }
    guard !record.members.isEmpty, record.members.allSatisfy({ $0.trashURL != nil }) else { return .locationUnknown }
    for member in record.members {
        let url = member.trashURL!
        guard let live = readMember(url) else { return pathExists(url) ? .cannotVerify : .trashMissing }
        if live.volumeKey != record.volumeKey || live.fileID != member.fileID || live.size != member.size
            || live.modificationDate != member.modificationDate { return .itemChanged }
    }
    return .cannotVerify
}
