import Foundation
import SnapsiftCore

public enum FolderWithdrawalReason: Equatable {
    case itemUnavailable(String)
    case memberMissing(URL)
    case identityChanged(URL)
    case sizeChanged(URL)
    case modificationDateChanged(URL)
    case volumeUnavailable(VolumeKey)
    case scanOnly(VolumeKey, VolumeCapabilityReason)
    case hashUnavailable(String)
    case hashMismatch(String)
    case membersChanged(String)
}

public struct FolderGroupWithdrawal {
    public let groupID: ReviewGroup.ID
    public let itemCount: Int
    public let reason: FolderWithdrawalReason
}

public struct FolderVolumeSummary {
    public let volumeKey: VolumeKey
    public let displayName: String
    public let isStartupVolume: Bool
    public let itemCount: Int
    public let totalBytes: Int
    public let capability: VolumeCapability
}

public struct FolderPreCommitSummary {
    public let itemCount: Int
    public let totalBytes: Int
    public let volumes: [FolderVolumeSummary]
    public let eligibleItemIDs: Set<String>
    public let withdrawals: [FolderGroupWithdrawal]
}

public enum FolderRemovalFailureReason {
    case liveCheck(FolderWithdrawalReason)
    case trash(String)
    case invalidTrashResult(URL?)
    case journalWrite(String)
    case rollbackFailed([URL], String)
}

public struct FolderRemovalFailure {
    public let itemID: String
    public let reason: FolderRemovalFailureReason
}

@MainActor
public struct FolderCommitCallbacks {
    public var onGroupsWithdrawn: (([FolderGroupWithdrawal]) -> Void)?
    public var onRemovalFailed: ((FolderRemovalFailure) -> Void)?
    /// Shared sweep callbacks describe protection changes. Withdrawals and
    /// filesystem failures are delivered only by the folder callbacks above.
    public var shared: CommitCallbacks

    public init(onGroupsWithdrawn: (([FolderGroupWithdrawal]) -> Void)? = nil,
                onRemovalFailed: ((FolderRemovalFailure) -> Void)? = nil,
                shared: CommitCallbacks? = nil) {
        self.onGroupsWithdrawn = onGroupsWithdrawn
        self.onRemovalFailed = onRemovalFailed
        self.shared = shared ?? CommitCallbacks()
    }
}

/// Folder identity/hash/volume gate followed by the unchanged shared sweep.
/// The caller retains FolderAccess for all scanned roots through this call.
@MainActor
public final class FolderCommitter {
    public let history: FolderHistoryStore
    private let trashPort: FolderTrashPort
    private let volumeProbe: (URL) -> VolumeProbeResult
    private let orchestrator = CommitOrchestrator()
    private var isCommitting = false

    public init(history: FolderHistoryStore? = nil,
                trashPort: FolderTrashPort? = nil,
                volumeProbe: @escaping (URL) -> VolumeProbeResult = probeVolume) {
        self.history = history ?? FolderHistoryStore()
        self.trashPort = trashPort ?? .system
        self.volumeProbe = volumeProbe
    }

    public func preCommitSummary(groups: [ReviewGroup], items: [FolderItem]) -> FolderPreCommitSummary {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var eligible: Set<String> = []
        var withdrawals: [FolderGroupWithdrawal] = []
        var candidates: [FolderItem] = []
        for group in groups where group.effectivelyArmed {
            let reason = group.photos.lazy.compactMap { photo -> FolderWithdrawalReason? in
                guard let item = byID[photo.uuid] else { return .itemUnavailable(photo.uuid) }
                return self.volumeFailure(item)
            }.first
            if let reason {
                withdrawals.append(FolderGroupWithdrawal(groupID: group.id,
                                                         itemCount: group.deletionIDs.count, reason: reason))
            } else { eligible.formUnion(group.deletionIDs) }
            candidates.append(contentsOf: group.deletionIDs.compactMap { byID[$0] })
        }
        let volumes = Dictionary(grouping: candidates, by: \.volumeKey).map { key, items in
            let probe = volumeProbe(items[0].primary.url)
            return FolderVolumeSummary(volumeKey: key, displayName: probe.displayName ?? key.rawValue,
                                       isStartupVolume: probe.facts.isRootFileSystem == true,
                                       itemCount: items.count, totalBytes: items.reduce(0) { $0 + $1.photo.size },
                                       capability: probe.capability)
        }.sorted { $0.volumeKey.rawValue < $1.volumeKey.rawValue }
        return FolderPreCommitSummary(itemCount: candidates.count,
                                      totalBytes: candidates.reduce(0) { $0 + $1.photo.size },
                                      volumes: volumes, eligibleItemIDs: eligible, withdrawals: withdrawals)
    }

    @discardableResult
    public func commit(groups: [ReviewGroup], items: [FolderItem], primaryHashes: [String: String],
                       isBusy: Bool = false, callbacks: FolderCommitCallbacks? = nil) async throws -> Int {
        guard !isBusy, !isCommitting else { throw CommitError.busy }
        isCommitting = true
        defer { isCommitting = false }
        let callbacks = callbacks ?? FolderCommitCallbacks()
        // Do not overwrite an unreconciled removal attempt.
        guard try history.pendingIntent().isEmpty else { throw FolderHistoryError.pendingIntent }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var accepted: [ReviewGroup] = []
        var withdrawals: [FolderGroupWithdrawal] = []
        var hashes: [String: String] = [:]
        for group in groups {
            guard group.effectivelyArmed else { accepted.append(group); continue }
            var failure: FolderWithdrawalReason?
            let exact = !Set(group.deletionIDs).intersection(group.autoSeeded).isEmpty
            for photo in group.photos {
                guard let item = byID[photo.uuid] else { failure = .itemUnavailable(photo.uuid); break }
                if let reason = liveFailure(item) { failure = reason; break }
                // Core intentionally does not re-sweep a previously protected,
                // force-included frame. New companions on it need fresh scan
                // facts rather than silently widening the reviewed move set.
                if photo.isProtected, group.deletionIDs.contains(item.id),
                   (try? sidecars(item))?.allSatisfy({ sidecar in
                       item.members.contains { $0.url == sidecar }
                   }) != true {
                    failure = .membersChanged(item.id); break
                }
                // Hash every candidate for history; an exact suggestion also
                // re-matches every primary in the group, including survivors.
                if exact || group.deletionIDs.contains(item.id) {
                    guard let digest = await FolderOriginalHasher(items: [item]).sha256(itemIdentifier: item.id)
                    else { failure = .hashUnavailable(item.id); break }
                    hashes[item.id] = digest
                    if exact && digest != primaryHashes[item.id] { failure = .hashMismatch(item.id); break }
                }
            }
            // Reads may have awaited hashing; validate the entire group again.
            if failure == nil {
                failure = group.photos.lazy.compactMap { byID[$0.uuid].flatMap(self.liveFailure) }.first
            }
            if let failure {
                withdrawals.append(FolderGroupWithdrawal(groupID: group.id,
                                                         itemCount: group.deletionIDs.count, reason: failure))
            } else { accepted.append(group) }
        }
        if !withdrawals.isEmpty { callbacks.onGroupsWithdrawn?(withdrawals) }
        var pending: [FolderHistoryRecord] = []
        var removed: Set<String> = []
        var persistenceFailed = false
        var latestItems: [String: FolderItem] = [:]
        let ports = CommitPorts<FolderItem, [FolderHistoryRecord]>(
            fetchLive: { ids in
                latestItems = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                    guard let scanned = byID[id], self.liveFailure(scanned) == nil,
                          let live = try? self.resolve(scanned) else { return nil }
                    return (id, live)
                })
                return latestItems
            },
            editedNow: { targets in
                // A directory read error fails closed as edited. Every target
                // has a value; Folder Mode never invents undetermined holes.
                Dictionary(uniqueKeysWithValues: targets.map { target in
                    (target.uuid, (try? self.sidecars(target.item))?.isEmpty != true)
                })
            },
            favoriteNow: { _ in false }, burstSiblings: { _ in nil },
            makeJournalEntry: { timestamp, records in
                records.compactMap { record in
                    guard let item = latestItems[record.assetIdentifier], let digest = hashes[item.id] else { return nil }
                    return FolderHistoryRecord(item: item, timestamp: timestamp,
                                               primarySHA256: digest, reason: record.reason)
                }
            },
            writeIntent: { entry in
                pending = entry
                do { try self.history.writeIntent(pending); return true }
                catch { return false }
            },
            delete: { _ in }, // Only the reporting performer is used by this source.
            appendAudit: { _ in
                do {
                    try self.history.append(pending.filter { removed.contains($0.itemID) && $0.state == .removed })
                    return true
                } catch { persistenceFailed = true; return false }
            },
            clearIntent: {
                // Keep partial rollback and failed writes for launch recovery.
                guard !persistenceFailed, !pending.contains(where: { $0.state == .rollbackFailed }) else { return }
                try? self.history.clearIntent()
            },
            deleteReporting: { targets in
                for (_, item) in targets {
                    guard let index = pending.firstIndex(where: { $0.itemID == item.id }) else { continue }
                    let outcome = self.remove(item, index: index, pending: &pending)
                    if let failure = outcome.failure {
                        callbacks.onRemovalFailed?(FolderRemovalFailure(itemID: item.id, reason: failure))
                    } else { removed.insert(item.id) }
                    if outcome.stop { persistenceFailed = true; break }
                }
                return removed
            })
        // A withdrawal leaves its group/marks untouched in the caller. Merge
        // shared flag updates back into the full group list before publishing.
        var shared = callbacks.shared
        let changed = shared.onGroupsChanged
        shared.onGroupsChanged = { updates in
            let byGroup = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
            changed?(groups.map { byGroup[$0.id] ?? $0 })
        }
        return try await orchestrator.commit(groups: accepted, ports: ports, callbacks: shared)
    }

    private func volumeFailure(_ item: FolderItem) -> FolderWithdrawalReason? {
        for member in item.members {
            let volume = volumeProbe(member.url)
            guard volume.volumeKey == member.volumeKey else { return .volumeUnavailable(member.volumeKey) }
            if case .scanOnly(let reason) = volume.capability { return .scanOnly(member.volumeKey, reason) }
        }
        return nil
    }

    private func liveFailure(_ item: FolderItem) -> FolderWithdrawalReason? {
        for member in item.members {
            guard let live = try? FolderMember.read(at: member.url) else {
                return volumeProbe(member.url.deletingLastPathComponent()).volumeKey == member.volumeKey
                    ? .memberMissing(member.url) : .volumeUnavailable(member.volumeKey)
            }
            if live.fileID != member.fileID || live.volumeKey != member.volumeKey { return .identityChanged(member.url) }
            if live.size != member.size { return .sizeChanged(member.url) }
            if live.modificationDate != member.modificationDate { return .modificationDateChanged(member.url) }
        }
        return volumeFailure(item)
    }

    private func sidecars(_ item: FolderItem) throws -> [URL] {
        let stems = Set(item.members.filter { !["xmp", "aae", "mov"].contains($0.url.pathExtension.lowercased()) }
            .map { $0.url.deletingPathExtension().lastPathComponent.lowercased() })
        return try FileManager.default.contentsOfDirectory(at: item.directoryURL, includingPropertiesForKeys: nil)
            .filter { ["xmp", "aae"].contains($0.pathExtension.lowercased())
                && stems.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            // Foundation can return /private/var entries for a /var parent.
            // Preserve the scanned directory spelling to avoid duplicate members.
            .map { item.directoryURL.appendingPathComponent($0.lastPathComponent).standardizedFileURL }
    }

    private func resolve(_ scanned: FolderItem) throws -> FolderItem {
        var members = try scanned.members.map { member in
            let live = try FolderMember.read(at: member.url)
            guard live.fileID == member.fileID, live.volumeKey == member.volumeKey,
                  live.size == member.size, live.modificationDate == member.modificationDate else {
                throw FolderSourceError.unreadableFile
            }
            // Keep the scan baseline for the immediate pre-move re-check.
            return member
        }
        for sidecar in try sidecars(scanned) where !members.contains(where: { $0.url == sidecar }) {
            members.append(try FolderMember.read(at: sidecar))
        }
        return FolderItem(photo: scanned.photo, primary: members.first { $0.url == scanned.primary.url }!,
                          members: members, directoryURL: scanned.directoryURL, folderKey: scanned.folderKey)
    }

    private func remove(_ item: FolderItem, index: Int, pending: inout [FolderHistoryRecord])
        -> (failure: FolderRemovalFailureReason?, stop: Bool) {
        if let reason = liveFailure(item) { return (.liveCheck(reason), false) }
        guard let sidecars = try? sidecars(item),
              sidecars.allSatisfy({ sidecar in item.members.contains { $0.url == sidecar } }) else {
            return (.liveCheck(.membersChanged(item.id)), false)
        }
        var moved: [Int] = []
        var failure: FolderRemovalFailureReason?
        var stop = false
        for memberIndex in pending[index].members.indices {
            let member = pending[index].members[memberIndex]
            do {
                let result = try trashPort.trash(member.originalURL)
                // Never roll back an unrelated file returned by a faulty port.
                let liveResult = result.flatMap { try? FolderMember.read(at: $0) }
                let sameFile = liveResult.map { $0.fileID == member.fileID && $0.size == member.size
                    && $0.modificationDate == member.modificationDate } == true
                pending[index].members[memberIndex].trashURL = sameFile ? result : nil
                if sameFile, !folderPathExists(member.originalURL) { moved.append(memberIndex) }
                guard validateTrashResult(sourceVolumeKey: item.volumeKey, resultingURL: result),
                      sameFile, !folderPathExists(member.originalURL) else {
                    failure = .invalidTrashResult(result); break
                }
                // Advance after EVERY member, including companions, so a crash
                // does not lose a completed member's known Trash location.
                if memberIndex == pending[index].members.indices.last { pending[index].state = .removed }
                try history.writeIntent(pending)
            } catch {
                if pending[index].members[memberIndex].trashURL != nil {
                    failure = .journalWrite(String(describing: error)); stop = true
                } else { failure = .trash(String(describing: error)) }
                break
            }
        }
        if let failure {
            var stranded: [URL] = []
            for memberIndex in moved.reversed() {
                let member = pending[index].members[memberIndex]
                do {
                    try trashPort.move(member.trashURL!, member.originalURL)
                    pending[index].members[memberIndex].trashURL = nil
                } catch { stranded.append(member.trashURL!) }
            }
            // A move without a resulting URL cannot be reversed or guessed.
            let unknown = pending[index].members.contains { !folderPathExists($0.originalURL) }
            pending[index].state = stranded.isEmpty && !unknown ? .pending : .rollbackFailed
            do { try history.writeIntent(pending) }
            catch { stop = true }
            if !stranded.isEmpty || unknown {
                return (.rollbackFailed(stranded, String(describing: failure)), stop)
            }
            return (failure, stop)
        }
        return (nil, false)
    }
}
