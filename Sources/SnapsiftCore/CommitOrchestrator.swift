import Foundation

/// A blocked commit is distinct from a successful commit of zero items.
public enum CommitError: Error {
    case busy
    case journalWriteFailed
}

/// Source effects for one commit. Identifiers are opaque; a source without
/// burst stacks returns nil from `burstSiblings`. The journal payload belongs
/// to the source, including any recovery policy or source-specific metadata.
@MainActor
public struct CommitPorts<Item, JournalEntry> {
    public var fetchLive: ([String]) -> [String: Item]
    public var editedNow: @MainActor ([(uuid: String, item: Item)]) async -> [String: Bool]
    public var favoriteNow: (Item) -> Bool
    public var burstSiblings: (Item) -> [String]?
    public var timestamp: () -> String
    public var makeJournalEntry: (String, [DeletionRecord]) -> JournalEntry
    public var writeIntent: (JournalEntry) -> Bool
    public var delete: @MainActor ([Item]) async throws -> Void
    public var appendAudit: (JournalEntry) -> Bool
    public var clearIntent: () -> Void

    public init(fetchLive: @escaping ([String]) -> [String: Item],
                editedNow: @escaping @MainActor ([(uuid: String, item: Item)]) async -> [String: Bool],
                favoriteNow: @escaping (Item) -> Bool,
                burstSiblings: @escaping (Item) -> [String]?,
                timestamp: @escaping () -> String = DeletionAuditLog.nowTimestamp,
                makeJournalEntry: @escaping (String, [DeletionRecord]) -> JournalEntry,
                writeIntent: @escaping (JournalEntry) -> Bool,
                delete: @escaping @MainActor ([Item]) async throws -> Void,
                appendAudit: @escaping (JournalEntry) -> Bool,
                clearIntent: @escaping () -> Void) {
        self.fetchLive = fetchLive
        self.editedNow = editedNow
        self.favoriteNow = favoriteNow
        self.burstSiblings = burstSiblings
        self.timestamp = timestamp
        self.makeJournalEntry = makeJournalEntry
        self.writeIntent = writeIntent
        self.delete = delete
        self.appendAudit = appendAudit
        self.clearIntent = clearIntent
    }
}

public struct CommitResult {
    public let deletedIDs: [String]
    public let auditFailed: Bool
}

/// Model/UI effects are synchronous except for the stale-item confirmation.
/// `onGroupsChanged` publishes sweep verdicts before the outcome callbacks.
/// `onCommitted` runs while the commit is still locked, after journal clearing.
@MainActor
public struct CommitCallbacks {
    public var staleWarning: (@MainActor (Int, Int) async -> Bool)?
    public var onProtectedDropped: ((Int) -> Void)?
    public var onBurstSkipped: ((Int) -> Void)?
    public var onUndeterminedSkipped: ((Int) -> Void)?
    public var onKeeperMissing: ((Int) -> Void)?
    public var onNoSurvivorLeft: ((Int) -> Void)?
    public var onGroupsChanged: (([ReviewGroup]) -> Void)?
    public var onCommittingChanged: ((Bool) -> Void)?
    public var saveSnapshot: (() -> Void)?
    public var beforeDelete: (() -> Void)?
    public var onCommitted: ((CommitResult) -> Void)?

    public init(staleWarning: (@MainActor (Int, Int) async -> Bool)? = nil,
                onProtectedDropped: ((Int) -> Void)? = nil,
                onBurstSkipped: ((Int) -> Void)? = nil,
                onUndeterminedSkipped: ((Int) -> Void)? = nil,
                onKeeperMissing: ((Int) -> Void)? = nil,
                onNoSurvivorLeft: ((Int) -> Void)? = nil,
                onGroupsChanged: (([ReviewGroup]) -> Void)? = nil,
                onCommittingChanged: ((Bool) -> Void)? = nil,
                saveSnapshot: (() -> Void)? = nil,
                beforeDelete: (() -> Void)? = nil,
                onCommitted: ((CommitResult) -> Void)? = nil) {
        self.staleWarning = staleWarning
        self.onProtectedDropped = onProtectedDropped
        self.onBurstSkipped = onBurstSkipped
        self.onUndeterminedSkipped = onUndeterminedSkipped
        self.onKeeperMissing = onKeeperMissing
        self.onNoSurvivorLeft = onNoSurvivorLeft
        self.onGroupsChanged = onGroupsChanged
        self.onCommittingChanged = onCommittingChanged
        self.saveSnapshot = saveSnapshot
        self.beforeDelete = beforeDelete
        self.onCommitted = onCommitted
    }
}

/// Shared commit safety and journal sequencing. A source-specific pre-gate may
/// withdraw groups before calling this; it does not alter the shared sweep.
@MainActor
public final class CommitOrchestrator {
    private var isCommitting = false

    public init() {}

    @discardableResult
    public func commit<Item, JournalEntry>(
        groups: [ReviewGroup],
        isBusy: Bool = false,
        ports: CommitPorts<Item, JournalEntry>,
        callbacks: CommitCallbacks? = nil
    ) async throws -> Int {
        guard !isBusy, !isCommitting else { throw CommitError.busy }
        let callbacks = callbacks ?? CommitCallbacks()
        isCommitting = true
        callbacks.onCommittingChanged?(true)
        defer {
            isCommitting = false
            callbacks.onCommittingChanged?(false)
        }

        var groups = groups
        let states = groups.indices.map { i in
            CommitGroupState(index: i, photos: groups[i].photos, keeperID: groups[i].keeperID,
                             rejected: groups[i].rejected,
                             includeProtected: groups[i].includeProtected)
        }
        let candidateIDs = states.flatMap { st in
            st.photos.filter {
                isEffectiveDeletion($0, rejected: st.rejected, includeProtected: st.includeProtected)
            }.map(\.uuid)
        }
        guard !candidateIDs.isEmpty else { return 0 }

        // Resolve every promised survivor as well as every candidate. A fetch
        // limited to the nominated keeper would withdraw valid groups or miss
        // the last survivor when the keeper itself is marked for deletion.
        let survivorIDs = states.flatMap { st -> [String] in
            guard st.photos.contains(where: {
                isEffectiveDeletion($0, rejected: st.rejected, includeProtected: st.includeProtected)
            }) else { return [] }
            return survivors(photos: st.photos, rejected: st.rejected,
                             includeProtected: st.includeProtected).map(\.uuid)
        }
        let live = ports.fetchLive(Array(Set(candidateIDs).union(survivorIDs)))
        let sweepTargets: [(uuid: String, item: Item)] = states.flatMap { st in
            st.photos.compactMap { p -> (uuid: String, item: Item)? in
                guard isEffectiveDeletion(p, rejected: st.rejected,
                                          includeProtected: st.includeProtected),
                      !p.isProtected, let item = live[p.uuid] else { return nil }
                return (p.uuid, item)
            }
        }
        let editedNow = sweepTargets.isEmpty ? [:] : await ports.editedNow(sweepTargets)
        var favoriteNow: [String: Bool] = [:]
        for (uuid, item) in sweepTargets { favoriteNow[uuid] = ports.favoriteNow(item) }
        let decision = commitSweepDecision(
            groups: states,
            live: LiveCommitFacts(resolved: Set(live.keys),
                                  favoriteNow: favoriteNow, editedNow: editedNow))

        var flagsChanged = false
        for frame in decision.swept {
            guard let j = groups[frame.groupIndex].photos
                .firstIndex(where: { $0.uuid == frame.uuid }) else { continue }
            switch frame.reason {
            case .newlyProtected:
                groups[frame.groupIndex].photos[j] = groups[frame.groupIndex].photos[j]
                    .with(favorite: frame.favorite, edited: frame.edited)
                groups[frame.groupIndex].rejected.remove(frame.uuid)
                groups[frame.groupIndex].autoSeeded.remove(frame.uuid)
                flagsChanged = true
            case .undetermined:
                groups[frame.groupIndex].photos[j] = groups[frame.groupIndex].photos[j]
                    .with(editedUndetermined: true)
                groups[frame.groupIndex].rejected.remove(frame.uuid)
                groups[frame.groupIndex].autoSeeded.remove(frame.uuid)
                flagsChanged = true
            case .vanished:
                break   // the stale warning owns this; the mark stays
            }
        }
        if flagsChanged { callbacks.onGroupsChanged?(groups) }
        if decision.newlyProtectedCount > 0 { callbacks.onProtectedDropped?(decision.newlyProtectedCount) }
        if decision.undeterminedCount > 0 { callbacks.onUndeterminedSkipped?(decision.undeterminedCount) }
        if decision.keeperMissingCount > 0 { callbacks.onKeeperMissing?(decision.keeperMissingCount) }
        if decision.noSurvivorLeftCount > 0 { callbacks.onNoSurvivorLeft?(decision.noSurvivorLeftCount) }

        let ids = decision.deleteIDs
        guard !ids.isEmpty else {
            if flagsChanged { callbacks.saveSnapshot?() }
            return 0
        }
        var items = ids.compactMap { id in live[id].map { (id: id, item: $0) } }
        guard !items.isEmpty else {
            if flagsChanged { callbacks.saveSnapshot?() }
            return 0
        }
        if decision.vanishedCount > 0, let warn = callbacks.staleWarning {
            guard await warn(decision.vanishedCount, items.count) else { return 0 }
        }

        // A representative may remove an entire stack. It is admissible only
        // when every live sibling is in this commit's deletion set.
        var burstSkipped: Set<String> = []
        let deletionSet = Set(ids)
        for (id, item) in items {
            if let siblings = ports.burstSiblings(item),
               !siblings.allSatisfy({ deletionSet.contains($0) }) {
                burstSkipped.insert(id)
            }
        }
        if !burstSkipped.isEmpty {
            items = items.filter { !burstSkipped.contains($0.id) }
            callbacks.onBurstSkipped?(burstSkipped.count)
            guard !items.isEmpty else { callbacks.saveSnapshot?(); return 0 }
        }

        let resolvable = Set(items.map(\.id))
        let timestamp = ports.timestamp()
        var auditRecords: [DeletionRecord] = []
        for g in groups {
            let deletionIDs = g.deletionIDs.filter { resolvable.contains($0) }
            guard !deletionIDs.isEmpty else { continue }
            let keeperDeleted = deletionIDs.contains(g.keeperID)
            let keeperPhoto = keeperDeleted ? nil : g.photos.first { $0.uuid == g.keeperID }
            let keeperID = keeperDeleted ? "" : g.keeperID
            let keeperFilename = keeperPhoto?.filename ?? ""
            for deletedID in deletionIDs {
                guard let p = g.photos.first(where: { $0.uuid == deletedID }) else { continue }
                auditRecords.append(DeletionRecord(
                    timestamp: timestamp, assetIdentifier: p.uuid,
                    filename: p.filename, sizeBytes: p.size,
                    keeperIdentifier: keeperID, keeperFilename: keeperFilename,
                    reason: DeletionAuditLog.reason(
                        for: p, includeProtectedActive: g.includeProtected,
                        autoSeededExact: g.autoSeeded.contains(deletedID))))
            }
        }

        callbacks.beforeDelete?()
        let entry = ports.makeJournalEntry(timestamp, auditRecords)
        if !auditRecords.isEmpty, !ports.writeIntent(entry) {
            throw CommitError.journalWriteFailed
        }
        do {
            try await ports.delete(items.map(\.item))
        } catch {
            ports.clearIntent()
            throw error
        }
        let auditFailed = !auditRecords.isEmpty && !ports.appendAudit(entry)
        ports.clearIntent()
        callbacks.onCommitted?(CommitResult(deletedIDs: items.map(\.id), auditFailed: auditFailed))
        return items.count
    }
}
