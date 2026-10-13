import Foundation
import Combine
import Photos
import SnapsiftCore
import SnapsiftPhotoKit

/// Observable macOS shell over the shared Photos scan, review and commit session.
@MainActor
final class LibraryModel: ObservableObject {
    typealias ScanKind = PhotoLibrarySession.ScanKind
    private let session: PhotoLibrarySession
    private var localization = L10n(Language.detect())
    @Published var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var showSaveRotationConfirm = false
    @Published var saveRotationError: Error?
    @Published var saveRotationSuccess = false
    @Published var searchQuery = "" { didSet { apfelMatched = nil } }
    @Published var apfelMatched: Set<String>?
    @Published var apfelSearching = false
    var apfelAvailable: Bool { Apfel.isInstalled }

    init() {
        session = PhotoLibrarySession(
            storage: PhotoLibraryStorage(directory: DeletionAuditLog.directory),
            albumTitles: AlbumWriter.titles(L10n(Language.detect())),
            enrichment: MacPhotoLibraryEnrichment())
        session.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    private func configure(_ t: L10n) {
        localization = t
        session.configure(albumTitles: AlbumWriter.titles(t), namingLanguage: t.language.rawValue,
                          fallbackSetName: t.setFallbackName())
    }

    var groups: [ReviewGroup] { session.groups }
    var isScanning: Bool { session.isScanning }
    var isDeleting: Bool { session.isDeleting }
    var includeVideo: Bool {
        get { session.includeVideo }
        set { session.includeVideo = newValue }
    }
    var qualityAvailable: Bool { session.qualityAvailable }
    var libraryIdentity: LibraryIdentity { session.libraryIdentity }
    var sidecarTrusted: Bool { session.sidecarTrusted }
    var undeterminedEditCount: Int { session.undeterminedEditCount }
    var unverifiableCount: Int { session.unverifiableCount }
    var unclassifiableCount: Int { session.unclassifiableCount }
    var uniqueMetadataWithheld: Int {
        get { session.uniqueMetadataWithheld }
        set { session.uniqueMetadataWithheld = newValue }
    }
    var uniqueMetadataIDs: Set<String> { session.uniqueMetadataIDs }
    var journalRecoveredCount: Int? {
        get { session.journalRecoveredCount }
        set { session.journalRecoveredCount = newValue }
    }
    var vanishedMarkCount: Int? {
        get { session.vanishedMarkCount }
        set { session.vanishedMarkCount = newValue }
    }
    var scanSource: ScanSource {
        get { session.scanSource }
        set { session.scanSource = newValue }
    }
    var albums: [AlbumItem] { session.albums }
    var refiningFaces: Bool { session.refiningFaces }
    var facesApplied: Bool { session.facesApplied }
    var categories: [CategoryBucket] { session.categories }
    var browseMode: Bool { session.browseMode }
    var exactDupeGroupIDs: Set<ReviewGroup.ID> { session.exactDupeGroupIDs }
    var isWritingAlbums: Bool { session.isWritingAlbums }
    var hasScanned: Bool { session.hasScanned }
    var staleRestoreClearedCount: Int? {
        get { session.staleRestoreClearedCount }
        set { session.staleRestoreClearedCount = newValue }
    }
    var lastDeleteAuditFailed: Bool { session.lastDeleteAuditFailed }
    var snapshotSaveFailedNotice: Bool {
        get { session.snapshotSaveFailedNotice }
        set { session.snapshotSaveFailedNotice = newValue }
    }
    var snapshotUnreadableNotice: Bool {
        get { session.snapshotUnreadableNotice }
        set { session.snapshotUnreadableNotice = newValue }
    }
    var progressFraction: Double? { session.progressFraction }
    var lastScanKind: ScanKind { session.lastScanKind }
    var displayRotation: [String: Int] { session.displayRotation }
    var totalDeletions: Int { session.totalDeletions }
    var userMarkCount: Int { session.userMarkCount }
    var confidentGroups: [ReviewGroup] { session.confidentGroups }
    var pendingGroups: [ReviewGroup] { session.pendingGroups }
    var reclaimableBytes: Int { session.reclaimableBytes }
    var imageManager: PHCachingImageManager { session.imageManager }
    var history: PhotoLibraryHistoryStore { session.history }

    var progress: String { session.progress.message(localization) }
    var scanNotice: String? {
        get { session.scanNotice?.message(localization) }
        set { if newValue == nil { session.scanNotice = nil } }
    }

    func requestAccess() async { auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    func loadAlbums() { session.loadAlbums() }
    func startScan(_ kind: ScanKind, _ t: L10n) { configure(t); session.startScan(kind) }
    func cancelScan() { session.cancelScan() }
    func refineWithFaces(_ t: L10n) async { configure(t); await session.refineWithFaces() }
    @discardableResult
    func restoreSnapshot(_ t: L10n, quiet: Bool = false) async -> Bool {
        configure(t)
        return await session.restoreSnapshot(quiet: quiet)
    }
    func reconcileDeletionJournal() { session.reconcileDeletionJournal() }
    func saveSnapshotNow() { session.saveSnapshotNow() }
    func flushSnapshotSync() { session.flushSnapshotSync() }
    func scheduleSnapshotSave() { session.scheduleSnapshotSave() }
    func asset(for id: String) -> PHAsset? { session.asset(for: id) }
    func rotation(for id: String) -> Int { session.rotation(for: id) }
    func rotate(frameID: String, clockwise: Bool) { session.rotate(frameID: frameID, clockwise: clockwise) }
    func displayAspect(for photo: Photo) -> Double { session.displayAspect(for: photo) }
    func loadReviewDetails(for ids: [String]) async { await session.loadReviewDetails(for: ids) }
    func reviewDetails(for id: String, t: L10n) -> String? {
        session.reviewAlbumNames(for: id).flatMap { t.reviewAlbums($0) }
    }
    func promote(group: ReviewGroup.ID, to id: String) { session.promote(group: group, to: id) }
    func keepOnly(group: ReviewGroup.ID, frame: String) { session.keepOnly(group: group, frame: frame) }
    func keepAll(group: ReviewGroup.ID) { session.keepAll(group: group) }
    func toggleKeepAll(group: ReviewGroup.ID) { session.toggleKeepAll(group: group) }
    @discardableResult
    func rejectAll(group: ReviewGroup.ID) -> Int { session.rejectAll(group: group) }
    func toggleDeleteAll(group: ReviewGroup.ID) { session.toggleDeleteAll(group: group) }
    @discardableResult
    func toggleReject(group: ReviewGroup.ID, frameID: String) -> Bool {
        session.toggleReject(group: group, frameID: frameID)
    }
    func forceReject(group: ReviewGroup.ID, frameID: String) { session.forceReject(group: group, frameID: frameID) }
    func setIncludeProtected(group: ReviewGroup.ID, value: Bool) {
        session.setIncludeProtected(group: group, value: value)
    }
    func withdrawnGroupIDs() async -> [ReviewGroup.ID: GroupWithdrawal] { await session.withdrawnGroupIDs() }

    func saveRotationToPhotos(frameID: String) async {
        guard rotation(for: frameID) != 0 else { return }
        do {
            try await session.saveRotationToPhotos(frameID: frameID)
            saveRotationSuccess = true
        } catch { saveRotationError = error }
    }

    @discardableResult
    func writeAlbums(_ t: L10n) async throws -> String {
        configure(t)
        let result = try await session.writeAlbums()
        return t.albumsWritten(bursts: result.bursts, blurry: result.blurry,
                               docs: result.documents, exact: result.exactDupes,
                               needsLook: result.needsLook, moved: result.moved)
    }

    @discardableResult
    func deleteReviewed(
        staleWarning: ((Int, Int) async -> Bool)? = nil,
        onProtectedDropped: ((Int) -> Void)? = nil,
        onBurstSkipped: ((Int) -> Void)? = nil,
        onUndeterminedSkipped: ((Int) -> Void)? = nil,
        onKeeperMissing: ((Int) -> Void)? = nil,
        onNoSurvivorLeft: ((Int) -> Void)? = nil
    ) async throws -> Int {
        try await session.deleteReviewed(staleWarning: staleWarning,
            onProtectedDropped: onProtectedDropped, onBurstSkipped: onBurstSkipped,
            onUndeterminedSkipped: onUndeterminedSkipped, onKeeperMissing: onKeeperMissing,
            onNoSurvivorLeft: onNoSurvivorLeft)
    }

    var filteredCategories: [CategoryBucket] {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return categories }
        if let matched = apfelMatched { return categories.filter { matched.contains($0.label) } }
        return categories.filter {
            $0.label.lowercased().contains(q) || $0.display.lowercased().contains(q)
        }
    }

    func runApfelSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, apfelAvailable, !apfelSearching else { return }
        apfelSearching = true
        defer { apfelSearching = false }
        if let matched = await Apfel.match(query: q, labels: categories.map(\.label)) {
            apfelMatched = Set(matched)
        }
    }
}
