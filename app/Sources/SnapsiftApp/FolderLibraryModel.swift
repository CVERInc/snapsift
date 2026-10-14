import SwiftUI
import AppKit
import SnapsiftCore
import SnapsiftFolder

/// macOS observation, folder picker, thumbnails and localization over the shared session.
@MainActor
final class FolderLibraryModel: ObservableObject, GroupReviewModel {
    typealias SelectedFolder = FolderLibrarySession.SelectedFolder
    private let session: FolderLibrarySession
    private var localization = L10n(Language.detect())
    private var scanLocalization = L10n(Language.detect())
    @Published private(set) var notice: String?
    @Published private(set) var historyReadError: String?
    @Published var operationReport: String? { didSet { if !updatingMessages && operationReport == nil { session.operationReport = nil } } }
    @Published var recoveryMessage: String? { didSet { if !updatingMessages && recoveryMessage == nil { session.recoveryOutcome = nil } } }
    @Published var errorMessage: String? { didSet { if !updatingMessages && errorMessage == nil { session.errorOutcome = nil } } }
    @Published var showSaveRotationConfirm = false
    let qualityAvailable = false
    let isFolderReview = true

    init(bookmarks: FolderBookmarkStore = FolderBookmarkStore(), history: FolderHistoryStore? = nil,
         trashPort: FolderTrashPort? = nil) {
        session = FolderLibrarySession(bookmarks: bookmarks, history: history ?? FolderHistoryStore(), trashPort: trashPort)
        session.onChange = { [weak self] in self?.objectWillChange.send() }
        session.onMessageChange = { [weak self] change in self?.messageChanged(change) }
    }

    var folders: [SelectedFolder] { session.folders }
    var review: FolderReviewState { session.review }
    var result: FolderScanResult? { session.result }
    var uniqueMetadataIDs: Set<String> { session.uniqueMetadataIDs }
    var crossFolderItemIDs: Set<String> { session.crossFolderItemIDs }
    var isScanning: Bool { session.isScanning }
    var hasScanned: Bool { session.hasScanned }
    var activity: FolderActivityState { session.activity }
    var historyEntries: [FolderHistoryEntry] { session.historyEntries }
    var groups: [ReviewGroup] { session.groups }
    var isBusy: Bool { session.isBusy }
    var canScan: Bool { session.canScan }
    var canReviewRemoval: Bool { session.canReviewRemoval }
    var userMarkCount: Int { session.userMarkCount }
    var totalDeletions: Int { session.totalDeletions }
    var crossFolderMatches: [[String]] { session.crossFolderMatches }
    var removalReview: FolderRemovalReview? {
        get { session.removalReview }
        set { session.removalReview = newValue }
    }
    var showHistory: Bool {
        get { session.showHistory }
        set { session.showHistory = newValue }
    }
    var selection: ReviewGroup.ID? {
        get { session.selection }
        set { session.selection = newValue }
    }
    var focusedFrame: String? {
        get { session.focusedFrame }
        set { session.focusedFrame = newValue }
    }
    private var updatingMessages = false
    private func messageChanged(_ change: FolderSessionMessageChange) {
        updatingMessages = true
        defer { updatingMessages = false }
        switch change {
        case .notice(let outcome):
            let t: L10n
            switch outcome {
            case .scanFinished?, .scanCancelled?: t = scanLocalization
            default: t = localization
            }
            notice = outcome?.message(t)
        case .error(let outcome):
            if isScanning { errorMessage = outcome?.message(scanLocalization) }
            else { errorMessage = outcome?.message(localization) }
        case .recovery(let outcome): recoveryMessage = outcome?.message(localization)
        case .historyReadError(let error): historyReadError = error.map { localization.folderHistoryFailed($0.localizedDescription) }
        case .operationReport(let reports):
            if let reports, let old = session.operationReport, reports.count == old.count + 1,
               case .historyFailed(let error)? = reports.last {
                operationReport = [operationReport, localization.folderHistoryFailed(error.localizedDescription)]
                    .compactMap { $0 }.joined(separator: "\n\n")
            } else {
                operationReport = reports.map { $0.map { $0.message(localization) }.joined(separator: "\n\n") }
            }
        }
    }
    func item(for id: String) -> FolderItem? { session.item(for: id) }

    func loadFolders(_ t: L10n) { localization = t; session.loadFolders() }
    func chooseFolders(_ t: L10n) {
        guard !isScanning, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = t.folderChoose()
        guard panel.runModal() == .OK else { return }
        localization = t
        session.addFolders(panel.urls)
    }
    func removeFolder(_ id: UUID, _ t: L10n) {
        guard !isScanning, !isBusy else { return }
        localization = t
        session.removeFolder(id)
    }
    func startScan(_ t: L10n) {
        guard canScan else { return }
        localization = t
        scanLocalization = t
        session.startScan()
    }
    func cancelScan() { session.cancelScan() }
    func discardResult() { session.discardResult() }
    func rotation(for id: String) -> Int { 0 }
    func displayAspect(for photo: Photo) -> Double {
        photo.height > 0 ? Double(photo.width) / Double(photo.height) : 1
    }
    func reviewThumbnail(for photo: Photo, box: CGSize) -> AnyView {
        AnyView(FolderThumbnail(id: photo.uuid, provider: result?.imageProvider, box: box))
    }
    func reviewDetails(for id: String, t: L10n) -> String? {
        guard let item = session.item(for: id), item.members.count > 1 else { return nil }
        return t.folderMembers(item.members.count, kinds: item.members.map { $0.url.pathExtension.uppercased() }.joined(separator: " + "))
    }
    func reviewFormat(for id: String) -> FolderReviewFormat? {
        session.item(for: id).map { folderReviewFormat(for: $0) }
    }
    func promote(group: ReviewGroup.ID, to id: String) { session.promote(group: group, to: id) }
    /// True when this press was ⇧K's undo (the group is back as it was).
    @discardableResult
    func keepOnly(group: ReviewGroup.ID, frame id: String) -> Bool { session.keepOnly(group: group, frame: id) }
    func keepAll(group: ReviewGroup.ID) { session.keepAll(group: group) }
    func toggleDeleteAll(group: ReviewGroup.ID) { session.toggleDeleteAll(group: group) }
    func setIncludeProtected(group: ReviewGroup.ID, value: Bool) { session.setIncludeProtected(group: group, value: value) }
    @discardableResult func toggleReject(group: ReviewGroup.ID, frameID: String) -> Bool {
        session.toggleReject(group: group, frameID: frameID)
    }
    func forceReject(group: ReviewGroup.ID, frameID: String) { session.forceReject(group: group, frameID: frameID) }
    func reconcileAtLaunch(_ t: L10n) {
        guard !isBusy else { return }
        localization = t
        session.reconcileAtLaunch()
    }
    func presentRemovalReview() { session.presentRemovalReview() }
    func cancelRemovalReview() { session.cancelRemovalReview() }
    func commitReviewed(_ payload: FolderRemovalReview, _ t: L10n) async {
        guard activity.operation == .reviewing, removalReview?.id == payload.id, result != nil else { return }
        localization = t
        await session.commitReviewed(payload)
    }
    func presentHistory(_ t: L10n) {
        guard !isBusy, !isScanning else { return }
        localization = t
        session.presentHistory()
    }
    func refreshHistory(_ t: L10n) {
        guard !isBusy, !isScanning else { return }
        localization = t
        session.refreshHistory()
    }
    func putBack(_ entry: FolderHistoryEntry, _ t: L10n) async {
        guard !isScanning, !isBusy else { return }
        localization = t
        await session.putBack(entry)
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
