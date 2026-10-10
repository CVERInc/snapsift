import SwiftUI
import AppKit
import SnapsiftCore
import SnapsiftFolder
import SnapsiftAppSupport

@MainActor
final class FolderLibraryModel: ObservableObject, GroupReviewModel {
    struct SelectedFolder: Identifiable {
        let id: UUID
        var url: URL?
        var wasStale = false
        var unavailable = false
    }

    @Published private(set) var folders: [SelectedFolder] = []
    @Published private(set) var review = FolderReviewState()
    @Published private(set) var result: FolderScanResult?
    @Published private(set) var uniqueMetadataIDs: Set<String> = []
    @Published private(set) var crossFolderItemIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var activity = FolderActivityState()
    @Published var removalReview: FolderRemovalReview?
    @Published var showHistory = false
    @Published private(set) var historyEntries: [FolderHistoryEntry] = []
    @Published private(set) var historyReadError: String?
    @Published var operationReport: String?
    @Published var recoveryMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var notice: String?
    @Published var selection: ReviewGroup.ID?
    @Published var focusedFrame: String?
    // Required only by the shared Photos gallery adapter. Folder review never
    // exposes a rotation-save button or supplies a PhotoKit effect.
    var showSaveRotationConfirm = false
    let qualityAvailable = false
    let isFolderReview = true
    private let bookmarks: FolderBookmarkStore
    private let history: FolderHistoryStore
    private let committer: FolderCommitter
    private let trashPort: FolderTrashPort
    private var loaded = false
    private var reconciledAtLaunch = false
    private var reconciliationFailed = false
    private var scanTask: Task<Void, Never>?
    private var itemsByID: [String: FolderItem] = [:]

    init(bookmarks: FolderBookmarkStore = FolderBookmarkStore(), history: FolderHistoryStore? = nil,
         trashPort: FolderTrashPort? = nil) {
        self.bookmarks = bookmarks
        let store = history ?? FolderHistoryStore()
        let port = trashPort ?? .system
        self.history = store
        self.trashPort = port
        self.committer = FolderCommitter(history: store, trashPort: port)
    }
    // FolderAccess balances remaining scopes when the retained result releases.
    deinit { scanTask?.cancel() }
    var groups: [ReviewGroup] { review.groups }
    var isBusy: Bool { activity.isBusy }
    var canScan: Bool { !isScanning && !isBusy && !showHistory && !folders.isEmpty }
    var canReviewRemoval: Bool {
        guard !isScanning, !isBusy, !showHistory, let result else { return false }
        let supported = Set(result.roots.filter { $0.volume.capability == .removalSupported }.compactMap { $0.volume.volumeKey })
        return groups.contains { group in
            group.deletionIDs.contains { itemsByID[$0].map { supported.contains($0.volumeKey) } == true }
        }
    }
    var userMarkCount: Int { groups.reduce(0) { $0 + $1.rejected.subtracting($1.autoSeeded).count } }
    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }
    func item(for id: String) -> FolderItem? { itemsByID[id] }
    var crossFolderMatches: [[String]] {
        (result?.crossFolderDuplicates ?? []).map { $0.itemIDs.filter { itemsByID[$0] != nil } }.filter { $0.count > 1 }
    }

    func loadFolders(_ t: L10n) {
        guard !loaded else { return }
        loaded = true
        refreshFolders(t)
    }

    private func refreshFolders(_ t: L10n) {
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
        } catch { errorMessage = t.folderBookmarkError(error.localizedDescription) }
    }

    func chooseFolders(_ t: L10n) {
        guard !isScanning, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = t.folderChoose()
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls {
                let existing = folders.first { $0.url?.standardizedFileURL == url.standardizedFileURL }
                if let existing, !existing.unavailable { continue }
                try bookmarks.add(url)
                if let existing { try bookmarks.remove(existing.id) }
            }
        } catch { errorMessage = t.folderBookmarkError(error.localizedDescription) }
        refreshFolders(t)
    }

    func removeFolder(_ id: UUID, _ t: L10n) {
        guard !isScanning, !isBusy else { return }
        do {
            try bookmarks.remove(id)
            discardResult()
            refreshFolders(t)
        } catch { errorMessage = t.folderBookmarkError(error.localizedDescription) }
    }

    func startScan(_ t: L10n) {
        guard canScan else { return }
        // Only folder results and their scopes are discarded. This model has
        // no LibraryModel, ScanSnapshotStore or DeletionAuditLog reference.
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
                let scanned = try await FolderScanPipeline.scan(roots: resolved.map(\.url))
                let metadata = await Task.detached(priority: .utility) {
                    await FolderMetadataProbe(items: scanned.items).metadata(for: scanned.items.map(\.id))
                }.value
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
                self.notice = t.folderScanFinished(items: scanned.items.count, groups: self.groups.count)
            } catch is CancellationError {
                self.notice = t.folderScanCancelled()
            } catch {
                self.refreshFolders(t)
                self.errorMessage = t.folderScanError(error.localizedDescription)
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    func discardResult() {
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

    func rotation(for id: String) -> Int { 0 }
    func displayAspect(for photo: Photo) -> Double {
        photo.height > 0 ? Double(photo.width) / Double(photo.height) : 1
    }
    func reviewThumbnail(for photo: Photo, box: CGSize) -> AnyView {
        AnyView(FolderThumbnail(id: photo.uuid, provider: result?.imageProvider, box: box))
    }
    func reviewDetails(for id: String, t: L10n) -> String? {
        guard let item = itemsByID[id], item.members.count > 1 else { return nil }
        return t.folderMembers(item.members.count, kinds: item.members.map { $0.url.pathExtension.uppercased() }.joined(separator: " + "))
    }
    func reviewFormat(for id: String) -> FolderReviewFormat? {
        itemsByID[id].map { folderReviewFormat(for: $0) }
    }
    func promote(group: ReviewGroup.ID, to id: String) { if !isBusy { review.apply(.promote(id), to: group) } }
    func keepOnly(group: ReviewGroup.ID, frame id: String) { if !isBusy { review.apply(.keepOnly(id), to: group) } }
    func keepAll(group: ReviewGroup.ID) { if !isBusy { review.apply(.keepAll, to: group) } }
    func toggleDeleteAll(group: ReviewGroup.ID) { if !isBusy { review.apply(.toggleDeleteAll, to: group) } }
    func setIncludeProtected(group: ReviewGroup.ID, value: Bool) { if !isBusy { review.apply(.includeProtected(value), to: group) } }
    @discardableResult func toggleReject(group: ReviewGroup.ID, frameID: String) -> Bool {
        !isBusy && review.apply(.toggleReject(frameID), to: group)
    }
    func forceReject(group: ReviewGroup.ID, frameID: String) { if !isBusy { review.apply(.forceReject(frameID), to: group) } }

    private func historyAccesses() -> [FolderAccess] {
        ((try? bookmarks.load()) ?? []).compactMap { try? bookmarks.access($0.id).access }
    }

    /// Called by the outer app surface, including the Photos permission gate.
    func reconcileAtLaunch(_ t: L10n) {
        guard !reconciledAtLaunch, activity.begin(.reconciling) else { return }
        reconciledAtLaunch = true
        defer { activity.finish() }
        reconcileHistory(t)
    }

    private func reconcileHistory(_ t: L10n) {
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        do {
            let booked = try history.reconcileIntent()
            if reconciliationFailed { recoveryMessage = nil }
            reconciliationFailed = false
            if !booked.isEmpty {
                recoveryMessage = t.folderRecovered(booked.count, unavailable: booked.filter { !history.canPutBack($0) }.count)
            }
        } catch {
            reconciliationFailed = true
            recoveryMessage = t.folderReconcileFailed(error.localizedDescription)
            notice = nil
        }
    }

    func presentRemovalReview() {
        guard canReviewRemoval, let result, activity.begin(.reviewing) else { return }
        notice = nil
        operationReport = nil
        removalReview = FolderRemovalReview(summary: committer.preCommitSummary(groups: groups, items: result.items), groups: groups)
    }

    func cancelRemovalReview() {
        guard activity.operation == .reviewing else { return }
        removalReview = nil
        activity.finish()
    }

    func commitReviewed(_ payload: FolderRemovalReview, _ t: L10n) async {
        guard activity.operation == .reviewing, removalReview?.id == payload.id, let result else { return }
        removalReview = nil
        activity.finish()
        guard activity.begin(.committing) else { return }
        defer { activity.finish() }
        var problems: [String] = []
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
                            problems.append(([t.folderWithdrawalReport(withdrawal.itemCount, reason: withdrawal.reason)] + paths)
                                .joined(separator: "\n"))
                        }
                    },
                    onRemovalFailed: { failure in
                        failed.insert(failure.itemID)
                        let path = self.itemsByID[failure.itemID]?.primary.url.path ?? failure.itemID
                        problems.append("\(path)\n\(t.folderRemovalFailure(failure.reason))")
                    },
                    shared: CommitCallbacks(
                        // An unresolved live item can never be silently accepted.
                        staleWarning: { missing, _ in
                            problems.append(t.folderStale(missing)); return false
                        },
                        onProtectedDropped: { problems.append(t.folderNewlyProtected($0)) },
                        onBurstSkipped: { problems.append(t.commitBurstSkipped($0)) },
                        onUndeterminedSkipped: { problems.append(t.folderUnverifiedKept($0)) },
                        onKeeperMissing: { problems.append(t.folderKeeperMissing($0)) },
                        onNoSurvivorLeft: { problems.append(t.folderSurvivorsMissing($0)) },
                        onGroupsChanged: { self.review.groups = $0 },
                        onCommitted: { outcome in
                            self.review.finishRemoval(removed: Set(outcome.deletedIDs), failed: failed)
                            for id in outcome.deletedIDs { self.itemsByID.removeValue(forKey: id) }
                            self.uniqueMetadataIDs.subtract(outcome.deletedIDs)
                            self.crossFolderItemIDs = Set(self.crossFolderMatches.flatMap { $0 })
                            if outcome.auditFailed { problems.append(t.folderAuditFailed()) }
                        })))
        } catch { problems.append(t.folderCommitError(error)) }
        do {
            if !(try history.pendingIntent()).isEmpty { problems.append(t.folderPendingIntent()) }
        } catch { problems.append(t.folderHistoryFailed(error.localizedDescription)) }
        repairFocus()
        if problems.isEmpty { notice = removedCount == 0 ? t.folderNothingRemoved() : t.folderRemoved(removedCount) }
        else { operationReport = ([t.folderRemovalIncomplete(removedCount)] + problems).joined(separator: "\n\n") }
    }

    private func repairFocus() {
        if !groups.contains(where: { $0.id == selection }) { selection = groups.first?.id }
        let selected = groups.first { $0.id == selection }
        if selected?.photos.contains(where: { $0.uuid == focusedFrame }) != true { focusedFrame = selected?.keeperID }
    }

    func presentHistory(_ t: L10n) {
        guard !isBusy, !isScanning else { return }
        showHistory = true
        refreshHistory(t)
    }

    func refreshHistory(_ t: L10n) {
        guard !isBusy, !isScanning, activity.begin(.reconciling) else { return }
        defer { activity.finish() }
        reconcileHistory(t)
        reloadHistory(t)
    }

    private func reloadHistory(_ t: L10n) {
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        do {
            historyEntries = try history.entries()
            historyReadError = nil
        }
        catch {
            let problem = t.folderHistoryFailed(error.localizedDescription)
            historyReadError = problem
            operationReport = [operationReport, problem].compactMap { $0 }.joined(separator: "\n\n")
            notice = nil
        }
    }

    func putBack(_ entry: FolderHistoryEntry, _ t: L10n) async {
        guard !isScanning, activity.begin(.puttingBack) else { return }
        defer { activity.finish() }
        let accesses = historyAccesses()
        defer { accesses.forEach { $0.stop() } }
        operationReport = nil
        notice = nil
        await Task.yield()
        do {
            switch try history.putBack(entry.id, port: trashPort) {
            case .restored: notice = t.folderPutBackDone()
            case .unavailable: operationReport = t.folderHistoryUnavailable(folderHistoryUnavailableReason(entry.record))
            case .conflict(let urls): operationReport = t.folderPutBackConflict(urls)
            case .parentMissing(let urls): operationReport = t.folderPutBackParentMissing(urls)
            case .failed(let detail): operationReport = t.folderPutBackFailed(detail)
            case .rollbackFailed(let urls, let detail): operationReport = t.folderPutBackPartial(urls, detail: detail)
            }
        } catch { operationReport = t.folderPutBackPersistenceFailed(error.localizedDescription) }
        reloadHistory(t)
    }
}

private struct FolderThumbnail: View {
    let id: String
    let provider: FolderImageProvider?
    let box: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.reefDeep
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(Color.reefTextDim) }
        }
        .frame(width: box.width, height: box.height)
        .task(id: id) {
            guard let cg = await provider?.image(for: id, profile: .documentHighQuality), !Task.isCancelled else { return }
            image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
