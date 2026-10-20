import Foundation
import SnapsiftCore

@MainActor
public final class FolderLibrarySession {
    /// Called before observable state changes; the app supplies observation.
    public var onChange: (() -> Void)?
    public var onMessageChange: ((FolderSessionMessageChange) -> Void)?
    public struct SelectedFolder: Identifiable {
        public let id: UUID
        public var url: URL?
        public var wasStale = false
        public var unavailable = false
    }

    public private(set) var folders: [SelectedFolder] = [] { willSet { onChange?() } }
    public private(set) var review = FolderReviewState() { willSet { onChange?() } }
    public private(set) var result: FolderScanResult? { willSet { onChange?() } }
    public private(set) var uniqueMetadataIDs: Set<String> = [] { willSet { onChange?() } }
    public private(set) var crossFolderItemIDs: Set<String> = [] { willSet { onChange?() } }
    public private(set) var isScanning = false { willSet { onChange?() } }
    public private(set) var hasScanned = false { willSet { onChange?() } }
    public private(set) var activity = FolderActivityState() { willSet { onChange?() } }
    public var removalReview: FolderRemovalReview? { willSet { onChange?() } }
    public var showHistory = false { willSet { onChange?() } }
    public private(set) var historyEntries: [FolderHistoryEntry] = [] { willSet { onChange?() } }
    public private(set) var historyReadError: Error? { willSet { onChange?(); onMessageChange?(.historyReadError(newValue)) } }
    public var operationReport: [FolderOperationReport]? { willSet { onChange?(); onMessageChange?(.operationReport(newValue)) } }
    public var recoveryOutcome: FolderReconciliationOutcome? { willSet { onChange?(); onMessageChange?(.recovery(newValue)) } }
    public var errorOutcome: FolderSessionError? { willSet { onChange?(); onMessageChange?(.error(newValue)) } }
    public private(set) var notice: FolderSessionNotice? { willSet { onChange?(); onMessageChange?(.notice(newValue)) } }
    public var selection: ReviewGroup.ID? { willSet { onChange?() } }
    public var focusedFrame: String? { willSet { onChange?() } }
    public let bookmarks: FolderBookmarkStore
    public let history: FolderHistoryStore
    public let downloadStore: FolderDownloadStore?
    public var downloadedFiles: [FolderDownloadedFile] { downloadStore?.downloadedFiles ?? result?.downloadedFiles ?? [] }
    private let committer: FolderCommitter
    private let trashPort: FolderTrashPort
    private var loaded = false
    private var reconciledAtLaunch = false
    private var reconciliationFailed = false
    private var scanTask: Task<Void, Never>?
    private var itemsByID: [String: FolderItem] = [:]

    private let scan: ([URL]) async throws -> FolderScanResult
    private let metadata: ([FolderItem]) async -> [String: LibraryMetadata]

    /// Apps must supply their own bookmark and history locations.
    public init(bookmarks: FolderBookmarkStore, history: FolderHistoryStore,
                downloadStore: FolderDownloadStore? = nil,
                trashPort: FolderTrashPort? = nil,
                volumeProbe: @escaping (URL) -> VolumeProbeResult = probeVolume,
                scan: (([URL]) async throws -> FolderScanResult)? = nil,
                metadata: @escaping ([FolderItem]) async -> [String: LibraryMetadata] = { items in
                    await Task.detached(priority: .utility) {
                        await FolderMetadataProbe(items: items).metadata(for: items.map(\.id))
                    }.value
                }) {
        self.bookmarks = bookmarks
        self.history = history
        self.downloadStore = downloadStore
        let port = trashPort ?? .system
        self.trashPort = port
        self.committer = FolderCommitter(history: history, trashPort: port, volumeProbe: volumeProbe)
        // Custom scan closures must pass this same store to their pipeline.
        self.scan = scan ?? { try await FolderScanPipeline.scan(roots: $0, downloadStore: downloadStore) }
        self.metadata = metadata
    }
    // FolderAccess balances remaining scopes when the retained result releases.
    deinit { scanTask?.cancel() }
    public var groups: [ReviewGroup] { review.groups }
    public var isBusy: Bool { activity.isBusy }
    public var canScan: Bool { !isScanning && !isBusy && !showHistory && !folders.isEmpty }
    public var canReviewRemoval: Bool {
        guard !isScanning, !isBusy, !showHistory, let result else { return false }
        let supported = Set(result.roots.filter { $0.volume.capability == .removalSupported }.compactMap { $0.volume.volumeKey })
        return groups.contains { group in
            group.deletionIDs.contains { itemsByID[$0].map { supported.contains($0.volumeKey) } == true }
        }
    }
    public var userMarkCount: Int { groups.reduce(0) { $0 + $1.rejected.subtracting($1.autoSeeded).count } }
    public var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }
    public func item(for id: String) -> FolderItem? { itemsByID[id] }
    public var crossFolderMatches: [[String]] {
        (result?.crossFolderDuplicates ?? []).map { $0.itemIDs.filter { itemsByID[$0] != nil } }.filter { $0.count > 1 }
    }

    public func loadFolders() {
        guard !loaded else { return }
        loaded = true
        refreshFolders()
    }

    private func refreshFolders() {
        do {
            let old = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            folders = try bookmarks.load().map { bookmark in
                do {
                    let resolved = try bookmarks.access(bookmark.id)
                    defer { resolved.access.stop() }
                    return SelectedFolder(id: bookmark.id, url: resolved.access.url,
                                          wasStale: resolved.wasStale || old[bookmark.id]?.wasStale == true)
                } catch {
                    return SelectedFolder(id: bookmark.id, url: old[bookmark.id]?.url, unavailable: true)
                }
            }
        } catch { errorOutcome = .bookmark(error) }
    }

    public func addFolders(_ urls: [URL]) {
        guard !isScanning, !isBusy else { return }
        do {
            for url in urls {
                let existing = folders.first { $0.url?.standardizedFileURL == url.standardizedFileURL }
                if let existing, !existing.unavailable { continue }
                let added = try bookmarks.add(url)
                if let existing {
                    try bookmarks.remove(existing.id)
                    try downloadStore?.moveFolder(existing.id, to: added.id)
                }
            }
        } catch { errorOutcome = .bookmark(error) }
        refreshFolders()
    }

    public func removeFolder(_ id: UUID) {
        guard !isScanning, !isBusy else { return }
        do {
            try bookmarks.remove(id)
            try downloadStore?.forgetFolder(id)
            discardResult()
            refreshFolders()
        } catch { errorOutcome = .bookmark(error) }
    }

    public func startScan() {
        guard canScan else { return }
        // Discard only Folder results and scopes; Photos storage is unreachable.
        discardResult()
        notice = nil
        isScanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            var resolved: [FolderAccess] = []
            defer {
                resolved.forEach { $0.stop() }
                self.isScanning = false
                self.scanTask = nil
            }
            do {
                for index in self.folders.indices {
                    try Task.checkCancellation()
                    let root = try self.bookmarks.access(self.folders[index].id)
                    resolved.append(root.access)
                    self.folders[index].url = root.access.url
                    self.folders[index].wasStale = self.folders[index].wasStale || root.wasStale
                    self.folders[index].unavailable = false
                }
                let scanned = try await self.scan(resolved.map(\.url))
                let metadata = await self.metadata(scanned.items)
                // A decoder may finish after cancellation. Do not retain its
                // result or scopes and never install cancelled review decisions.
                if Task.isCancelled {
                    scanned.accesses.forEach { $0.stop() }
                    throw CancellationError()
                }
                self.result = scanned
                self.uniqueMetadataIDs = folderUniqueMetadataIDs(metadata)
                self.crossFolderItemIDs = Set(scanned.crossFolderDuplicates.flatMap(\.itemIDs))
                self.itemsByID = Dictionary(uniqueKeysWithValues: scanned.items.map { ($0.id, $0) })
                self.review = FolderReviewState(groups: folderReviewGroups(
                    scanned.groups, photos: scanned.items.map(\.photo),
                    crossFolderMatches: scanned.crossFolderDuplicates.map(\.itemIDs)))
                self.hasScanned = true
                self.selection = self.groups.first?.id
                self.focusedFrame = self.groups.first?.keeperID
                self.notice = .scanFinished(items: scanned.items.count, groups: self.groups.count)
            } catch is CancellationError {
                self.notice = .scanCancelled
            } catch {
                self.refreshFolders()
                self.errorOutcome = .scan(error)
            }
        }
    }

    public func cancelScan() { scanTask?.cancel() }

    public func discardResult() {
        guard !isScanning, !isBusy else { return }
        result?.accesses.forEach { $0.stop() }
        result = nil
        uniqueMetadataIDs = []
        crossFolderItemIDs = []
        itemsByID = [:]
        review = FolderReviewState()
        selection = nil
        focusedFrame = nil
        hasScanned = false
        notice = nil
    }

    public func promote(group: ReviewGroup.ID, to id: String) { if !isBusy { review.apply(.promote(id), to: group) } }
    /// ⇧K. True when this press was the undo of the previous ⇧K on that frame.
    @discardableResult
    public func keepOnly(group: ReviewGroup.ID, frame id: String) -> Bool {
        guard !isBusy, case .undone? = review.keepOnly(id, in: group) else { return false }
        return true
    }
    public func keepAll(group: ReviewGroup.ID) { if !isBusy { review.apply(.keepAll, to: group) } }
    public func toggleDeleteAll(group: ReviewGroup.ID) { if !isBusy { review.apply(.toggleDeleteAll, to: group) } }
    public func setIncludeProtected(group: ReviewGroup.ID, value: Bool) { if !isBusy { review.apply(.includeProtected(value), to: group) } }
    @discardableResult public func toggleReject(group: ReviewGroup.ID, frameID: String) -> Bool {
        !isBusy && review.apply(.toggleReject(frameID), to: group)
    }
    public func forceReject(group: ReviewGroup.ID, frameID: String) { if !isBusy { review.apply(.forceReject(frameID), to: group) } }

    private func historyAccesses() -> [FolderAccess] {
        ((try? bookmarks.load()) ?? []).compactMap { try? bookmarks.access($0.id).access }
    }

    /// Called by the outer app surface, including the Photos permission gate.
    @discardableResult public func reconcileAtLaunch() -> FolderReconciliationOutcome? {
        guard !reconciledAtLaunch, activity.begin(.reconciling) else { return nil }
        reconciledAtLaunch = true
        defer { activity.finish() }
        return reconcileHistory()
    }

    @discardableResult private func reconcileHistory() -> FolderReconciliationOutcome {
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        do {
            let booked = try history.reconcileIntent()
            if reconciliationFailed { recoveryOutcome = nil }
            reconciliationFailed = false
            let outcome = FolderReconciliationOutcome.recovered(
                count: booked.count, unavailable: booked.filter { !history.canPutBack($0) }.count)
            if !booked.isEmpty { recoveryOutcome = outcome }
            return outcome
        } catch {
            reconciliationFailed = true
            recoveryOutcome = .failed(error)
            notice = nil
            return .failed(error)
        }
    }

    public func presentRemovalReview() {
        guard canReviewRemoval, let result, activity.begin(.reviewing) else { return }
        notice = nil
        operationReport = nil
        removalReview = FolderRemovalReview(summary: committer.preCommitSummary(groups: groups, items: result.items), groups: groups)
    }

    public func cancelRemovalReview() {
        guard activity.operation == .reviewing else { return }
        removalReview = nil
        activity.finish()
    }

    @discardableResult public func commitReviewed(_ payload: FolderRemovalReview) async -> FolderCommitOutcome? {
        guard activity.operation == .reviewing, removalReview?.id == payload.id, let result else { return nil }
        removalReview = nil
        activity.finish()
        guard activity.begin(.committing) else { return nil }
        defer { activity.finish() }
        var problems: [FolderCommitProblem] = []
        var failed: Set<String> = []
        var removedCount = 0
        do {
            removedCount = try await committer.commit(
                groups: payload.groups, items: result.items, primaryHashes: result.primaryHashes,
                callbacks: FolderCommitCallbacks(
                    onGroupsWithdrawn: { withdrawals in
                        for withdrawal in withdrawals {
                            let group = payload.groups.first { $0.id == withdrawal.groupID }
                            let paths = group?.deletionIDs.compactMap { self.itemsByID[$0]?.primary.url.path } ?? []
                            problems.append(.withdrawal(withdrawal, paths: paths))
                        }
                    },
                    onRemovalFailed: { failure in
                        failed.insert(failure.itemID)
                        let path = self.itemsByID[failure.itemID]?.primary.url.path ?? failure.itemID
                        problems.append(.removalFailed(failure, path: path))
                    },
                    shared: CommitCallbacks(
                        // An unresolved live item can never be silently accepted.
                        staleWarning: { missing, _ in
                            problems.append(.stale(missing)); return false
                        },
                        onProtectedDropped: { problems.append(.newlyProtected($0)) },
                        onBurstSkipped: { problems.append(.burstSkipped($0)) },
                        onUndeterminedSkipped: { problems.append(.unverifiedKept($0)) },
                        onKeeperMissing: { problems.append(.keeperMissing($0)) },
                        onNoSurvivorLeft: { problems.append(.survivorsMissing($0)) },
                        onGroupsChanged: { self.review.groups = $0 },
                        onCommitted: { outcome in
                            self.review.finishRemoval(removed: Set(outcome.deletedIDs), failed: failed)
                            for id in outcome.deletedIDs { self.itemsByID.removeValue(forKey: id) }
                            self.uniqueMetadataIDs.subtract(outcome.deletedIDs)
                            self.crossFolderItemIDs = Set(self.crossFolderMatches.flatMap { $0 })
                            if outcome.auditFailed { problems.append(.auditFailed) }
                        })))
        } catch { problems.append(.commitFailed(error)) }
        do {
            if !(try history.pendingIntent()).isEmpty { problems.append(.pendingIntent) }
        } catch { problems.append(.historyFailed(error)) }
        repairFocus()
        let outcome = FolderCommitOutcome(removedCount: removedCount, problems: problems)
        if problems.isEmpty { notice = removedCount == 0 ? .nothingRemoved : .removed(removedCount) }
        else { operationReport = [.removalIncomplete(outcome)] }
        return outcome
    }

    private func repairFocus() {
        if !groups.contains(where: { $0.id == selection }) { selection = groups.first?.id }
        let selected = groups.first { $0.id == selection }
        if selected?.photos.contains(where: { $0.uuid == focusedFrame }) != true { focusedFrame = selected?.keeperID }
    }

    public func presentHistory() {
        guard !isBusy, !isScanning else { return }
        showHistory = true
        refreshHistory()
    }

    public func refreshHistory() {
        guard !isBusy, !isScanning, activity.begin(.reconciling) else { return }
        defer { activity.finish() }
        reconcileHistory()
        reloadHistory()
    }

    private func reloadHistory() {
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        do {
            historyEntries = try history.entries()
            historyReadError = nil
        }
        catch {
            historyReadError = error
            operationReport = (operationReport ?? []) + [.historyFailed(error)]
            notice = nil
        }
    }

    public func putBack(_ entry: FolderHistoryEntry) async {
        guard !isScanning, activity.begin(.puttingBack) else { return }
        defer { activity.finish() }
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        operationReport = nil
        notice = nil
        await Task.yield()
        do {
            switch try history.putBack(entry.id, port: trashPort) {
            case .restored: notice = .putBackDone
            case .unavailable: operationReport = [.putBack(.unavailable(folderHistoryUnavailableReason(entry.record)))]
            case .conflict(let urls): operationReport = [.putBack(.conflict(urls))]
            case .parentMissing(let urls): operationReport = [.putBack(.parentMissing(urls))]
            case .failed(let detail): operationReport = [.putBack(.failed(detail))]
            case .rollbackFailed(let urls, let detail): operationReport = [.putBack(.rollbackFailed(urls, detail))]
            }
        } catch { operationReport = [.putBack(.persistenceFailed(error))] }
        reloadHistory()
    }
}
