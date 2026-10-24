import Foundation
import CoreGraphics
import ImageIO
import SnapsiftCore
import SnapsiftVision
@testable import SnapsiftFolder

private enum FolderModeFixtureError: Error { case image }

/// Accepts the shared generator's frames; no Folder-specific image generator or thresholds.
func writeFolderScanFrames(_ frames: [(name: String, image: CGImage, takenAt: Double)],
                           to root: URL) throws -> [FolderItem] {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try frames.map { frame in
        let url = root.appendingPathComponent(frame.name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw FolderModeFixtureError.image }
        CGImageDestinationAddImage(destination, frame.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FolderModeFixtureError.image }
        return try folderModeItem(url, takenAt: frame.takenAt,
                                  width: frame.image.width, height: frame.image.height)
    }
}

private func folderModeItem(_ url: URL, takenAt: Double = 0, width: Int = 640, height: Int = 480) throws -> FolderItem {
    let member = try FolderMember.read(at: url)
    let photo = Photo(uuid: url.path, filename: url.lastPathComponent, takenAt: takenAt,
                      width: width, height: height, size: member.size, uti: "public.png")
    return FolderItem(photo: photo, primary: member, members: [member],
                      directoryURL: url.deletingLastPathComponent(), folderKey: url.deletingLastPathComponent().path)
}

private struct FolderModeMetadata: UniqueMetadataProbe {
    func metadata(for ids: [String]) async -> [String: LibraryMetadata] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, LibraryMetadata(albumCount: 1, hasDescription: false)) })
    }
}

@MainActor
func checkFolderScanModes() async {
    print("Folder scan modes through enriched source fixtures")
    let defaults = FolderScanOptions()
    check(defaults.gapSec == ScanMode.Burst.gapSec && defaults.sizeTol == ScanMode.Burst.sizeTol
          && defaults.maxSpan == ScanMode.Burst.maxSpan && defaults.contentMaxDistance == ScanMode.burst.dHashDistance
          && defaults.contentConfidentSpread == ScanMode.Burst.confidentSpread
          && defaults.contentConfidentFeature == ScanMode.burst.featureDistance
          && defaults.lookAlikeHashDistance == ScanMode.lookAlikes.dHashDistance
          && defaults.lookAlikeFeatureDistance == ScanMode.lookAlikes.featureDistance,
          "folder combined: defaults read every unchanged shared comparison value")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-modes-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("fixture.png")
        try writeFolderImage(imageURL)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FolderModeFixtureError.image }
        let same = try writeFolderScanFrames([("a.png", image, 0), ("b.png", image, 1)], to: root.appendingPathComponent("same"))
        let away = try writeFolderScanFrames([("c.png", image, 100)], to: root.appendingPathComponent("away"))
        let provider = FolderImageProvider(items: same + away)
        func scan(_ items: [FolderItem], _ mode: ScanMode?, options: FolderScanOptions = .init()) async throws -> FolderScanPipeline.Grouping {
            await LookAlikeScanner.clearCache()
            return try await FolderScanPipeline.group(items: items, mode: mode, options: options,
                provider: provider, hasher: FolderOriginalHasher(items: items),
                metadataProbe: FolderModeMetadata(), documentCheck: { _ in false })
        }
        func members(_ result: FolderScanPipeline.Grouping) -> Set<Set<String>> {
            Set(result.groups.map { Set($0.photos.map(\.uuid)) })
        }
        for mode in ScanMode.allCases {
            let result = try await scan(same, mode)
            if mode == .burst {
                check(members(result) == [Set(same.map(\.id))], "folder burst: shared capture and dHash stages group the copies")
            } else {
                checkNeedsVision(members(result) == [Set(same.map(\.id))], "folder \(mode): shared comparison groups the two copies")
            }
            if mode == .similarSets {
                check(result.exact.isEmpty && result.groups.allSatisfy { !$0.confidentDupe && $0.rejected.isEmpty && $0.autoSeeded.isEmpty },
                      "folder sets: no confidence, exact suggestion or pre-mark")
            } else {
                checkNeedsVision(result.exact.count == 1 && result.groups.first?.rejected.count == 1
                    && result.groups.first?.autoSeeded == result.groups.first?.rejected,
                    "folder \(mode): same-folder exact copies pre-mark only the eligible non-keeper")
            }
            let cross = try await scan(same + away, mode)
            check(cross.cross.count == 1 && Set(cross.cross[0].itemIDs) == Set((same + away).map(\.id))
                  && cross.cross[0].folderKeys.count == 2,
                  "folder \(mode): primary-byte facts retain both locations regardless of capture time")
            check(cross.groups.allSatisfy { $0.rejected.isEmpty && $0.autoSeeded.isEmpty },
                  "folder \(mode): cross-folder copies never pre-mark, even the same-folder subset")
            checkNeedsVision(members(cross) == [Set((mode == .burst ? same : same + away).map(\.id))],
                             "folder \(mode): time-distant copy enters only the cross-time modes")
            let ids = cross.groups.flatMap { $0.photos.map(\.uuid) }
            check(ids.count == Set(ids).count, "folder \(mode): exact-first trimming never repeats an item")
            var unrelatedOptions = FolderScanOptions()
            unrelatedOptions.gapSec = 0; unrelatedOptions.maxSpan = 0
            unrelatedOptions.contentMaxDistance = -1; unrelatedOptions.lookAlikeHashDistance = -1
            unrelatedOptions.lookAlikeFeatureDistance = -1
            let fixed = try await scan(same, mode, options: unrelatedOptions)
            check(members(fixed) == members(result), "folder \(mode): legacy Folder thresholds cannot override a mode")
            let protected = [same[0], same[1].with(photo: same[1].photo.with(favorite: true))]
            let safe = try await scan(protected, mode)
            check(safe.groups.allSatisfy { !$0.deletionIDs.contains(same[1].id) },
                  "folder \(mode): protected copy stays out of suggestions")
        }
        let exactGroup = ReviewGroup(photos: same.map(\.photo), keeperID: same[0].id)
        let seeded = await seedFolderExactRejections(in: [exactGroup], exact: [exactGroup.id], items: same,
            metadataProbe: FolderModeMetadata(), documentCheck: { _ in false })
        check(seeded.groups[0].autoSeeded == [same[1].id] && seeded.groups[0].rejected == [same[1].id],
              "folder exact eligibility: verified same-folder copy seeds only the non-keeper")
        let withheld = await seedFolderExactRejections(in: [exactGroup], exact: [exactGroup.id], items: same + away,
            crossFolderItemIDs: Set((same + away).map(\.id)), metadataProbe: FolderModeMetadata(), documentCheck: { _ in false })
        check(withheld.groups[0].autoSeeded.isEmpty && withheld.groups[0].rejected.isEmpty,
              "folder exact eligibility: distant cross-folder copy withholds even a burst's same-folder marks")
        var protectedGroup = exactGroup
        protectedGroup.photos[1] = protectedGroup.photos[1].with(favorite: true)
        let protectedSeed = await seedFolderExactRejections(in: [protectedGroup], exact: [protectedGroup.id], items: same,
            metadataProbe: FolderModeMetadata(), documentCheck: { _ in false })
        check(protectedSeed.groups[0].rejected.isEmpty, "folder exact eligibility: protected copy never seeds")
        let combined = try await scan(same + away, nil)
        checkNeedsVision(members(combined) == [Set((same + away).map(\.id))] && combined.exact.count == 1
                         && combined.groups[0].confidentDupe && combined.groups[0].rejected.isEmpty,
                         "folder combined: unchanged exact-first group, confidence and cross-folder withholding")
        let combinedSame = try await scan(same, nil)
        checkNeedsVision(combinedSame.groups.count == 1 && combinedSame.groups[0].autoSeeded.count == 1,
                         "folder combined: same-folder copies still seed one item")
        let nearURL = same[1].primary.url
        try writeFolderImage(nearURL, variant: true)
        let near = [same[0], try folderModeItem(nearURL, takenAt: 1)]
        for mode in ScanMode.allCases {
            let result = try await scan(near, mode)
            checkNeedsVision(result.groups.count == 1, "folder \(mode): existing near-image fixture groups")
            check(result.exact.isEmpty && result.groups.allSatisfy { $0.autoSeeded.isEmpty && $0.rejected.isEmpty },
                  "folder \(mode): perceptually similar but different bytes never pre-mark")
        }
        await LookAlikeScanner.clearCache()
    } catch { check(false, "folder scan-mode fixture: \(error)") }
}

@MainActor
func checkFolderSetRemoval() async {
    print("Folder set session and removal through injected scans and Trash")
    for protected in [false, true] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-set-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let source = root.appendingPathComponent("source"), trash = root.appendingPathComponent("fake-trash")
            for dir in [source, trash] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            var items: [FolderItem] = []
            for name in ["a.png", "b.png"] {
                let url = source.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                items.append(try folderModeItem(url))
            }
            if protected { items[1] = items[1].with(photo: items[1].photo.with(favorite: true)) }
            let group = ReviewGroup(photos: items.map(\.photo), keeperID: items[0].id)
            let actual = probeVolume(at: source)
            let volume = VolumeProbeResult(facts: .init(isLocal: true, isReadOnly: false, mntRdOnly: false, fileSystemType: "apfs", isRootFileSystem: false),
                volumeKey: actual.volumeKey, displayName: "Fixture", volumeURL: root)
            let bookmarksURL = root.appendingPathComponent("folders.json")
            try JSONEncoder().encode([FolderBookmark(data: Data())]).write(to: bookmarksURL)
            let bookmarks = FolderBookmarkStore(url: bookmarksURL, resolveBookmark: { _ in (source, false) })
            let history = FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                intentURL: root.appendingPathComponent("intent.json"))
            var modes: [ScanMode] = [], combinedCalls = 0
            func result() -> FolderScanResult {
                FolderScanResult(items: items, groups: [group], exactGroupIDs: [], crossFolderDuplicates: [],
                    roots: [.init(url: source, volume: volume)], issues: [], primaryHashes: [:],
                    uniqueMetadataWithheld: 0, uniqueMetadataIDs: [], knownCarryingIDs: [], imageProvider: FolderImageProvider(items: items), accesses: [])
            }
            let port = FolderTrashPort(trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FolderTrashPort.moveWithoutOverwrite(url, destination)
                return destination
            })
            let session = FolderLibrarySession(bookmarks: bookmarks, history: history, trashPort: port,
                volumeProbe: { _ in volume }, scan: { _ in combinedCalls += 1; return result() },
                modeScan: { _, mode in modes.append(mode); return result() },
                metadata: { items in await FolderModeMetadata().metadata(for: items.map(\.id)) })
            session.loadFolders()
            for mode in ScanMode.allCases {
                session.startScan(mode)
                while session.isScanning { await Task.yield() }
                check(session.scanMode == mode && session.groups.count == 1,
                      "folder session: injected \(mode) result retains its mode")
            }
            check(modes == ScanMode.allCases && combinedCalls == 0, "folder session: per-mode scans use their injection only")
            let id = session.groups[0].id
            check(session.groups[0].rejected.isEmpty, "folder sets: every item starts kept")
            check(session.toggleReject(group: id, frameID: items[0].id), "folder sets: nominee can be unchecked")
            check(session.toggleReject(group: id, frameID: items[1].id) == !protected,
                  "folder sets: ordinary uncheck excludes protection")
            check(Set(session.groups[0].deletionIDs) == Set((protected ? [items[0]] : items).map(\.id)),
                  "folder sets: no-survivor choice contains every explicitly unchecked item")
            session.presentRemovalReview()
            guard let review = session.removalReview else { check(false, "folder sets: removal review available"); continue }
            let outcome = await session.commitReviewed(review)
            let expected = protected ? 1 : 2
            check(outcome?.removedCount == expected && outcome?.problems.isEmpty == true,
                  "folder sets: Trash commit removes \(expected) explicitly unchecked items")
            check(try history.records().count == expected, "folder sets: every removed item has history")
            check(FileManager.default.fileExists(atPath: items[1].primary.url.path) == protected,
                  "folder sets: protected item remains; fully unchecked set leaves no item")
            session.discardResult()
            check(session.scanMode == nil, "folder session: discarding clears the mode")
            session.startScan()
            while session.isScanning { await Task.yield() }
            check(session.scanMode == nil && combinedCalls == 1, "folder session: macOS combined entry stays kindless and injected")
        } catch { check(false, "folder set removal fixture: \(error)") }
    }
}

@MainActor
func checkFolderCrossFolderModeGroups() async {
    print("Folder modes surface cross-folder bytes without a readable comparison")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-cross-mode-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let sources = [root.appendingPathComponent("a"), root.appendingPathComponent("b")]
        var items: [FolderItem] = []
        for source in sources {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let url = source.appendingPathComponent("unreadable.png")
            try Data("identical bytes without a readable preview".utf8).write(to: url)
            items.append(try folderModeItem(url))
        }
        let bookmarksURL = root.appendingPathComponent("folders.json")
        try JSONEncoder().encode([FolderBookmark(data: Data())]).write(to: bookmarksURL)
        let session = FolderLibrarySession(
            bookmarks: FolderBookmarkStore(url: bookmarksURL, resolveBookmark: { _ in (sources[0], false) }),
            history: FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                intentURL: root.appendingPathComponent("intent.json")),
            modeScan: { _, _ in
                FolderScanResult(items: items, groups: [], exactGroupIDs: [],
                    crossFolderDuplicates: [.init(primarySHA256: "identical", itemIDs: items.map(\.id),
                                                  folderKeys: Set(items.map(\.folderKey)))],
                    roots: [], issues: [], primaryHashes: [:], uniqueMetadataWithheld: 0, uniqueMetadataIDs: [], knownCarryingIDs: [],
                    imageProvider: FolderImageProvider(items: items), accesses: [])
            }, metadata: { _ in [:] })
        session.loadFolders()
        for mode in ScanMode.allCases {
            session.startScan(mode)
            while session.isScanning { await Task.yield() }
            check(session.result != nil && session.scanMode == mode, "folder cross bytes: \(mode) scan installed")
            if mode == .lookAlikes {
                check(session.groups.count == 1 && Set(session.groups[0].photos.map(\.uuid)) == Set(items.map(\.id)),
                      "folder look-alikes: unreadable cross-folder pair surfaces as one group")
                check(session.groups.allSatisfy { $0.rejected.isEmpty && $0.autoSeeded.isEmpty },
                      "folder look-alikes: informational cross-folder pair has no marks")
            } else {
                check(session.groups.isEmpty, "folder \(mode): cross-folder facts do not create comparison groups")
            }
        }
    } catch { check(false, "folder cross-folder mode fixture: \(error)") }
}
