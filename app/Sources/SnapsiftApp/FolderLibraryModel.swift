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
    private var loaded = false
    private var scanTask: Task<Void, Never>?
    private var itemsByID: [String: FolderItem] = [:]

    init(bookmarks: FolderBookmarkStore = FolderBookmarkStore()) { self.bookmarks = bookmarks }
    // FolderAccess balances remaining scopes when the retained result releases.
    deinit { scanTask?.cancel() }
    var groups: [ReviewGroup] { review.groups }
    var canScan: Bool { !isScanning && !folders.isEmpty }
    var userMarkCount: Int { groups.reduce(0) { $0 + $1.rejected.subtracting($1.autoSeeded).count } }
    var totalDeletions: Int { groups.reduce(0) { $0 + $1.deletionIDs.count } }

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
        guard !isScanning else { return }
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
        guard !isScanning else { return }
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
        guard !isScanning else { return }
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
    func promote(group: ReviewGroup.ID, to id: String) { review.apply(.promote(id), to: group) }
    func keepOnly(group: ReviewGroup.ID, frame id: String) { review.apply(.keepOnly(id), to: group) }
    func keepAll(group: ReviewGroup.ID) { review.apply(.keepAll, to: group) }
    func toggleDeleteAll(group: ReviewGroup.ID) { review.apply(.toggleDeleteAll, to: group) }
    func setIncludeProtected(group: ReviewGroup.ID, value: Bool) { review.apply(.includeProtected(value), to: group) }
    @discardableResult func toggleReject(group: ReviewGroup.ID, frameID: String) -> Bool {
        review.apply(.toggleReject(frameID), to: group)
    }
    func forceReject(group: ReviewGroup.ID, frameID: String) { review.apply(.forceReject(frameID), to: group) }
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
