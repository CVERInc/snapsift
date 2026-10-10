import SwiftUI
import SnapsiftCore
import SnapsiftAppSupport

/// The gallery's concrete Photos and Folder adapters share review controls,
/// while image access, decisions and persistence stay with their own model.
@MainActor
protocol GroupReviewModel: ObservableObject {
    var qualityAvailable: Bool { get }
    var isFolderReview: Bool { get }
    var uniqueMetadataIDs: Set<String> { get }
    var showSaveRotationConfirm: Bool { get set }
    func rotation(for id: String) -> Int
    func displayAspect(for photo: Photo) -> Double
    func reviewThumbnail(for photo: Photo, box: CGSize) -> AnyView
    func reviewDetails(for id: String, t: L10n) -> String?
    func reviewFormat(for id: String) -> FolderReviewFormat?
    func promote(group: ReviewGroup.ID, to: String)
    func keepAll(group: ReviewGroup.ID)
    func toggleDeleteAll(group: ReviewGroup.ID)
    func setIncludeProtected(group: ReviewGroup.ID, value: Bool)
}

extension GroupReviewModel {
    func reviewFormat(for id: String) -> FolderReviewFormat? { nil }
}

extension LibraryModel: GroupReviewModel {
    var isFolderReview: Bool { false }
    func reviewThumbnail(for photo: Photo, box: CGSize) -> AnyView {
        AnyView(AssetThumbnail(asset: asset(for: photo.uuid), manager: imageManager,
                               box: box, quarterTurns: rotation(for: photo.uuid), fill: true))
    }
    func reviewDetails(for id: String, t: L10n) -> String? { nil }
}
