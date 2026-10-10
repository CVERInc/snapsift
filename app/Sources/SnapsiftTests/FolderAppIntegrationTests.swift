import Foundation
import SnapsiftCore
import SnapsiftAppSupport

func folderAppIntegrationTests(_ check: (Bool, String) -> Void) {
    print("Folder app review state")
    let metadata = folderUniqueMetadataIDs([
        "tagged": LibraryMetadata(albumCount: 1, hasDescription: true),
        "plain": LibraryMetadata(albumCount: 1, hasDescription: false),
        "unknown": LibraryMetadata(albumCount: 1, hasDescription: nil),
    ])
    check(metadata == ["tagged"], "folder metadata badge includes observed tags/comments only, never unknown facts")
    let plain = ph(910, 0)
    let copy = ph(911, 1)
    let edited = ph(912, 2, edited: true)
    let unknown = ph(913, 3, docDegraded: true)
    let group = ReviewGroup(photos: [plain, copy, edited, unknown], keeperID: plain.uuid)
    var folder = FolderReviewState(groups: [group])
    let photos = FolderReviewState(groups: [group])

    check(!folder.apply(.toggleReject(edited.uuid), to: group.id), "folder normal mark refuses known protection")
    check(!folder.apply(.forceReject(unknown.uuid), to: group.id), "folder force mark refuses unverifiable image")
    folder.apply(.toggleDeleteAll, to: group.id)
    check(folder.groups[0].rejected == [copy.uuid], "folder bulk mark uses Core eligibility, preserving keeper and protections")
    check(photos.groups[0].rejected.isEmpty && photos.groups[0].keeperID == plain.uuid,
          "folder review mutation leaves independently retained Photos decisions unchanged")
    folder.apply(.includeProtected(true), to: group.id)
    check(folder.groups[0].deletionIDs.sorted() == [copy.uuid, edited.uuid].sorted(),
          "folder confirmed override includes known protection only")
    folder.apply(.promote(edited.uuid), to: group.id)
    check(!folder.groups[0].includeProtected && !folder.groups[0].rejected.contains(edited.uuid),
          "folder promoting last protected rejection clears its override")
    folder.apply(.keepOnly(copy.uuid), to: group.id)
    check(folder.groups[0].keeperID == copy.uuid && folder.groups[0].rejected == [plain.uuid],
          "folder keep-only composes Core rules and preserves protected/unknown frames")
    folder.apply(.keepAll, to: group.id)
    check(folder.groups[0].rejected.isEmpty && folder.groups[0].autoSeeded.isEmpty,
          "folder keep-all clears local suggestions and marks")

    folder.apply(.toggleReject(plain.uuid), to: group.id)
    folder.apply(.toggleReject(copy.uuid), to: group.id)
    check(folder.groups[0].keeperID == edited.uuid, "folder rejecting standing keeper nominates a survivor")
    check(!folder.apply(.promote("missing"), to: group.id), "folder rejects missing frame action")
    check(!folder.apply(.keepAll, to: UUID()), "folder rejects missing group action")

    folder.apply(.keepAll, to: group.id)
    folder.apply(.forceReject(edited.uuid), to: group.id)
    check(folder.groups[0].includeProtected && folder.groups[0].deletionIDs == [edited.uuid]
          && folder.groups[0].autoSeeded.isEmpty,
          "folder force mark records explicit consent and user attribution")
    folder.apply(.keepOnly(copy.uuid), to: group.id)
    check(folder.groups[0].includeProtected && folder.groups[0].rejected.contains(edited.uuid),
          "folder keep-only preserves a previously confirmed protected mark")
    folder.apply(.includeProtected(false), to: group.id)
    check(!folder.groups[0].includeProtected && !folder.groups[0].rejected.contains(edited.uuid),
          "folder revoking consent removes protected marks")
    folder.apply(.toggleDeleteAll, to: group.id)
    check(folder.groups[0].rejected.isEmpty, "folder bulk toggle off clears every mark")

    var seeded = group
    seeded.rejected = [copy.uuid]
    seeded.autoSeeded = [copy.uuid]
    let projected = folderReviewGroups([seeded], photos: [plain, copy, edited, unknown],
                                      crossFolderMatches: [[copy.uuid, edited.uuid]])
    check(projected[0].rejected.isEmpty && projected[0].autoSeeded.isEmpty,
          "cross-folder match clears a pipeline pre-mark and its suggestion attribution")
    check(projected.count == 1, "cross-folder projection does not repeat already grouped items")

    let companion = ph(914, 4)
    let standalone = folderReviewGroups([seeded], photos: [plain, copy, edited, unknown, companion],
                                       crossFolderMatches: [[copy.uuid, companion.uuid]])
    check(standalone.count == 2 && standalone[1].photos.map(\.uuid) == [companion.uuid],
          "cross-folder grouped-file item absent from near groups gets a review card")
    check(standalone[1].rejected.isEmpty && standalone[1].autoSeeded.isEmpty,
          "cross-folder informational card never receives a pre-mark")
    check(Set(standalone.flatMap { $0.photos.map(\.uuid) }).count == 5,
          "cross-folder projection preserves unique item identity across review groups")
    check(seeded.rejected == [copy.uuid] && seeded.autoSeeded == [copy.uuid],
          "cross-folder projection does not mutate its input groups")
    let allCross = folderReviewGroups([], photos: [plain, copy], crossFolderMatches: [[plain.uuid, copy.uuid]])
    check(allCross.count == 1 && allCross[0].photos.count == 2 && allCross[0].rejected.isEmpty,
          "cross-folder-only result is visible with both members unmarked")
}
