import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SnapsiftCore
import SnapsiftFolder
import UniformTypeIdentifiers

private struct HarnessError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
private final class CheckReporter {
    private(set) var checks: [(label: String, passed: Bool)] = []

    var failures: Int { checks.filter { !$0.passed }.count }

    func check(_ passed: Bool, _ label: String) {
        checks.append((label, passed))
        print("\(passed ? "✓ PASS" : "✗ FAIL"): \(label)")
    }

    func note(_ text: String) { print("  · \(text)") }

    func printTable() {
        print("\n| Result | Check |")
        print("| --- | --- |")
        for check in checks {
            print("| \(check.passed ? "PASS" : "FAIL") | \(check.label.replacingOccurrences(of: "|", with: "\\|")) |")
        }
        print("\n\(checks.count - failures) passed, \(failures) failed")
    }
}

@MainActor
private func expect(_ condition: Bool, _ label: String, reporter: CheckReporter) throws {
    reporter.check(condition, label)
    if !condition { throw HarnessError(message: label) }
}

private struct Options {
    var externalPath: String?
    var makeImage = false

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--make-image":
                guard !result.makeImage else { throw HarnessError(message: "--make-image was provided more than once") }
                result.makeImage = true
                index += 1
            case "--external":
                guard result.externalPath == nil, index + 1 < arguments.count else {
                    throw HarnessError(message: "--external requires one mounted-volume path")
                }
                result.externalPath = arguments[index + 1]
                index += 2
            default:
                throw HarnessError(message: "Unknown argument: \(arguments[index])")
            }
        }
        guard !(result.makeImage && result.externalPath != nil) else {
            throw HarnessError(message: "Choose either --external <mounted-volume-path> or --make-image")
        }
        return result
    }
}

private struct FixtureSet {
    let files: [URL]
    let sameFolderKeeper: String
    let sameFolderCopy: String
    let crossFolderLeft: String
    let crossFolderRight: String
    let taggedFilename: String
    let livePhotoFilename: String
    let rawFilename: String
    let editedFilename: String
    let livePhotoMovieFilename: String
    let rawFilenameCompanion: String
    let sidecarFilename: String
    let taggedURL: URL
}

@MainActor
private final class VolumeRun {
    let label: String
    let root: URL
    let fixtureRoot: URL
    let stateDirectory: URL
    let history: FolderHistoryStore
    let reporter: CheckReporter
    let isStartupVolume: Bool
    let volumeKey: VolumeKey
    let volumeRoot: URL?
    private let startupTrashDirectory: URL?
    private var fixtureFiles: [URL: Data] = [:]
    private var accesses: [FolderAccess] = []
    private var finished = false
    private var safeToRemoveRoot = true

    init(label: String, parent: URL, isStartupVolume: Bool,
         volumeRoot: URL?, reporter: CheckReporter) throws {
        self.label = label
        self.reporter = reporter
        self.isStartupVolume = isStartupVolume
        self.volumeRoot = volumeRoot?.standardizedFileURL

        guard let parentKey = probeVolume(at: parent).volumeKey else {
            throw HarnessError(message: "\(label): volume identity is unavailable for its parent directory")
        }
        let url = parent.appendingPathComponent("snapsift-folder-live-\(UUID().uuidString.lowercased())",
                                                isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: url) } }
        root = url.standardizedFileURL
        fixtureRoot = root.appendingPathComponent("fixtures", isDirectory: true)
        stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: false)
        history = FolderHistoryStore(
            historyURL: stateDirectory.appendingPathComponent("folder-history.json"),
            intentURL: stateDirectory.appendingPathComponent("pending-removal.json"))
        if isStartupVolume {
            startupTrashDirectory = try? FileManager.default.url(
                for: .trashDirectory, in: .userDomainMask, appropriateFor: root, create: false)
                .standardizedFileURL
        } else {
            startupTrashDirectory = nil
        }

        guard let key = probeVolume(at: root).volumeKey, key == parentKey else {
            throw HarnessError(message: "\(label): volume identity is unavailable for the throwaway root")
        }
        volumeKey = key
        initialized = true
    }

    func exercise() async throws {
        reporter.note("\(label) throwaway root: \(root.path)")
        let fixtures = try createFixtures()
        for file in fixtures.files { fixtureFiles[file] = try Data(contentsOf: file) }

        let result = try await FolderScanPipeline.scan(roots: [fixtureRoot])
        accesses = result.accesses
        let itemsByName = Dictionary(result.items.map { ($0.primary.url.lastPathComponent, $0) },
                                     uniquingKeysWith: { first, _ in first })

        reporter.check(result.issues.isEmpty, "\(label): pipeline reports no fixture enumeration issues")
        let expectedNames: Set<String> = [fixtures.sameFolderKeeper, fixtures.sameFolderCopy,
                                          fixtures.crossFolderLeft, fixtures.crossFolderRight,
                                          fixtures.taggedFilename, fixtures.livePhotoFilename,
                                          fixtures.rawFilename, fixtures.editedFilename]
        reporter.check(expectedNames.isSubset(of: Set(itemsByName.keys)),
                       "\(label): pipeline discovers every generated photo fixture")

        guard let sameA = itemsByName[fixtures.sameFolderKeeper],
              let sameB = itemsByName[fixtures.sameFolderCopy],
              let crossA = itemsByName[fixtures.crossFolderLeft],
              let crossB = itemsByName[fixtures.crossFolderRight],
              let tagged = itemsByName[fixtures.taggedFilename],
              let live = itemsByName[fixtures.livePhotoFilename],
              let raw = itemsByName[fixtures.rawFilename],
              let edited = itemsByName[fixtures.editedFilename] else {
            reporter.check(false, "\(label): all expected photo fixtures resolve to scanned items")
            throw HarnessError(message: "\(label): a generated photo fixture was not scanned")
        }

        reporter.check(Set(live.members.map { $0.url.lastPathComponent })
                       == Set([fixtures.livePhotoFilename, fixtures.livePhotoMovieFilename]),
                       "\(label): Live Photo image and movie form one grouped item")
        reporter.check(Set(raw.members.map { $0.url.lastPathComponent })
                       == Set([fixtures.rawFilename, fixtures.rawFilenameCompanion]),
                       "\(label): RAW and JPEG form one grouped item")
        reporter.check(edited.photo.edited && edited.photo.isProtected
                       && edited.members.contains(where: { $0.url.lastPathComponent == fixtures.sidecarFilename }),
                       "\(label): XMP sidecar protects its photo and belongs to its item")

        let sameIDs = Set([sameA.id, sameB.id])
        let sameBytesMatch = try Data(contentsOf: sameA.primary.url) == Data(contentsOf: sameB.primary.url)
        reporter.check(sameA.folderKey == sameB.folderKey && sameBytesMatch,
                       "\(label): same-folder fixture files are byte-identical")
        let sameGroup = result.groups.first { Set($0.photos.map(\.uuid)) == sameIDs }
        reporter.check(sameGroup.map { result.exactGroupIDs.contains($0.id) } == true,
                       "\(label): same-folder byte-identical pair is an exact group")
        reporter.check(sameGroup.map { !$0.autoSeeded.isEmpty && $0.rejected == $0.autoSeeded } == true,
                       "\(label): same-folder exact duplicate is pre-marked")

        let crossIDs = Set([crossA.id, crossB.id])
        let crossBytesMatch = try Data(contentsOf: crossA.primary.url) == Data(contentsOf: crossB.primary.url)
        reporter.check(crossA.folderKey != crossB.folderKey && crossBytesMatch,
                       "\(label): cross-folder fixture files are byte-identical in separate folders")
        let crossGroup = result.groups.first { Set($0.photos.map(\.uuid)) == crossIDs }
        reporter.check(result.crossFolderDuplicates.contains {
            Set($0.itemIDs) == crossIDs && $0.folderKeys.count == 2
        }, "\(label): cross-folder byte-identical pair is surfaced")
        reporter.check(crossGroup.map { $0.autoSeeded.isEmpty && $0.rejected.isEmpty } == true,
                       "\(label): cross-folder exact pair is not pre-marked")

        let taggedSignals = FolderMetadataProbe.readSignals(at: tagged.primary.url)
        let taggedGroup = result.groups.first { $0.photos.contains(where: { $0.uuid == tagged.id }) }
        reporter.check(taggedSignals.hasTags == true,
                       "\(label): Finder tag is readable from the generated file")
        reporter.check(taggedGroup?.autoSeeded.contains(tagged.id) != true
                       && taggedGroup?.rejected.contains(tagged.id) != true,
                       "\(label): Finder-tagged photo is not pre-marked")
        reporter.check(result.uniqueMetadataIDs.contains(tagged.id)
                       && result.uniqueMetadataWithheld > 0,
                       "\(label): Finder tag is reported as unique metadata and withholds its suggestion")

        guard let sameGroup, sameGroup.effectivelyArmed,
              let candidateID = sameGroup.deletionIDs.first,
              let sameCandidate = result.items.first(where: { $0.id == candidateID }) else {
            reporter.check(false, "\(label): safe same-folder pre-mark is available for the real Trash pass")
            throw HarnessError(message: "\(label): the expected same-folder pre-mark was unavailable")
        }
        guard !edited.photo.isUnverifiable else {
            reporter.check(false, "\(label): force-included sidecar photo has determined protection facts")
            throw HarnessError(message: "\(label): sidecar photo is unverifiable and cannot be force-included")
        }

        var forced = ReviewGroup(photos: [edited.photo, live.photo], keeperID: live.id)
        forced.rejected = [edited.id]
        forced.includeProtected = true
        let groups = [sameGroup, forced]
        let committer = FolderCommitter(history: history, trashPort: .system)
        let summary = committer.preCommitSummary(groups: groups, items: result.items)
        reporter.check(summary.eligibleItemIDs == Set([candidateID, edited.id])
                       && summary.itemCount == 2 && summary.volumes.count == 1,
                       "\(label): pre-commit summary includes the pre-mark and force-included grouped item")
        reporter.check(history.historyURL.path.hasPrefix(root.path + "/state/")
                       && history.intentURL.path.hasPrefix(root.path + "/state/"),
                       "\(label): history and journal are isolated inside this throwaway root")

        var removals: [FolderRemovalFailure] = []
        var withdrawals: [FolderGroupWithdrawal] = []
        let callbacks = FolderCommitCallbacks(
            onGroupsWithdrawn: { withdrawals.append(contentsOf: $0) },
            onRemovalFailed: { removals.append($0) })
        let count = try await committer.commit(groups: groups, items: result.items,
                                               primaryHashes: result.primaryHashes, callbacks: callbacks)
        reporter.check(count == 2 && withdrawals.isEmpty && removals.isEmpty,
                       "\(label): FolderCommitter moves both reviewed items through the real system Trash")
        reporter.check(try history.pendingIntent().isEmpty,
                       "\(label): committer clears its intent journal after recording history")

        var records = try history.records()
        reporter.check(records.count == 2,
                       "\(label): history contains the pre-marked and force-included removals")
        guard records.count == 2,
              let exactRecordIndex = records.firstIndex(where: { $0.itemID == candidateID }),
              let forcedRecordIndex = records.firstIndex(where: { $0.itemID == edited.id }) else {
            throw HarnessError(message: "\(label): expected history entries were not recorded")
        }
        reporter.check(records[exactRecordIndex].reason == .exactDuplicate,
                       "\(label): pre-marked history entry records exact-duplicate reason")
        reporter.check(records[forcedRecordIndex].reason == .forceIncludedProtectedEdited
                       && records[forcedRecordIndex].members.contains(where: {
                           $0.originalURL.pathExtension.lowercased() == "xmp"
                       }), "\(label): force-included history includes the XMP member")
        try assertTrashLocations(records, source: sameCandidate.primary.url)
        reporter.check(records.allSatisfy { $0.state == .removed && history.canPutBack($0) },
                       "\(label): every real Trash history entry is available for Put Back")
        reporter.check(records.allSatisfy { record in
            record.members.allSatisfy { !FileManager.default.fileExists(atPath: $0.originalURL.path) }
        }, "\(label): all committed members left their original paths")

        let recoveryURL = try makeDirectory(fixtureRoot, name: "reconciliation")
            .appendingPathComponent("RecoveryProbe.jpg")
        try writeJPEG(recoveryURL, seed: 97, captureDate: "2021:04:05 06:07:08")
        fixtureFiles[recoveryURL] = try Data(contentsOf: recoveryURL)
        let recoveryEnumeration = try FolderEnumerator.enumerate(root: recoveryURL.deletingLastPathComponent())
        guard let recoveryItem = recoveryEnumeration.items.first(where: { $0.primary.url == recoveryURL }) else {
            throw HarnessError(message: "\(label): reconciliation fixture did not enumerate")
        }
        guard let recoveryHash = await FolderOriginalHasher(items: [recoveryItem])
            .sha256(itemIdentifier: recoveryItem.id) else {
            throw HarnessError(message: "\(label): reconciliation fixture hash was unavailable")
        }
        var crashRecord = FolderHistoryRecord(item: recoveryItem, timestamp: "live-harness-crash",
                                              primarySHA256: recoveryHash, reason: .userRejected)
        try history.writeIntent([crashRecord])
        let recoveryTrashURL = try FolderTrashPort.system.trash(recoveryURL)
        guard let recoveryTrashURL else {
            throw HarnessError(message: "\(label): real Trash returned no recovery URL for reconciliation")
        }
        crashRecord.members[0].trashURL = recoveryTrashURL
        crashRecord.state = .removed
        try history.writeIntent([crashRecord])
        let recovered = try history.reconcileIntent()
        reporter.check(recovered.count == 1 && recovered[0].id == crashRecord.id
                       && recovered[0].state == .removed && history.canPutBack(recovered[0]),
                       "\(label): mid-commit journal reconciles to history with its recorded Trash URL")
        reporter.check(try history.pendingIntent().isEmpty,
                       "\(label): reconciliation clears the recovered intent")

        records = try history.records()
        reporter.check(records.count == 3,
                       "\(label): history includes both committed items and the recovered crash entry")
        try assertTrashLocations(records, source: sameCandidate.primary.url)

        if let forceRecord = records.first(where: { $0.itemID == edited.id }),
           let conflictMember = forceRecord.members.first {
            let conflictBytes = Data("Snapsift Folder Live Tests conflict sentinel".utf8)
            try conflictBytes.write(to: conflictMember.originalURL)
            let conflictResult = try history.putBack(forceRecord.id)
            let didRefuse: Bool
            if case .conflict(let conflicts) = conflictResult {
                didRefuse = conflicts == [conflictMember.originalURL]
                    && (try? Data(contentsOf: conflictMember.originalURL)) == conflictBytes
            } else { didRefuse = false }
            reporter.check(didRefuse,
                           "\(label): Put Back refuses an existing original and leaves it untouched")
            try FileManager.default.removeItem(at: conflictMember.originalURL)
            let retry = try history.putBack(forceRecord.id)
            reporter.check(isRestored(retry),
                           "\(label): force-included grouped item restores after the conflict is removed")
        } else {
            reporter.check(false, "\(label): force-included history entry is available for the conflict check")
        }

        for record in records where record.itemID != edited.id {
            let result = try history.putBack(record.id)
            reporter.check(isRestored(result),
                           "\(label): Put Back restores history entry \(record.itemID == candidateID ? "pre-marked" : "reconciled")")
        }

        let allRestored = fixtureFiles.allSatisfy { url, expected in
            FileManager.default.fileExists(atPath: url.path) && (try? Data(contentsOf: url)) == expected
        }
        reporter.check(allRestored,
                       "\(label): all generated originals return byte-identical to their source paths")
        reporter.check(FolderMetadataProbe.readSignals(at: fixtures.taggedURL).hasTags == true,
                       "\(label): Finder tag remains with the restored original")
        let finalRecords = try history.records()
        let intentIsClear = try history.pendingIntent().isEmpty
        reporter.check(finalRecords.count == 3 && finalRecords.allSatisfy { $0.state == .restored }
                       && intentIsClear,
                       "\(label): every history entry is restored and the journal is empty")
        reporter.check(finalRecords.flatMap(\.members).compactMap(\.trashURL).allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        }, "\(label): no recorded throwaway item remains in Trash after Put Back")
    }

    func cleanup(removeRoot: Bool) {
        guard !finished else { return }
        accesses.forEach { $0.stop() }
        accesses.removeAll()

        var safeToRemoveRoot = true
        do {
            if !(try history.pendingIntent()).isEmpty {
                _ = try history.reconcileIntent()
            }
            for entry in try history.entries() where entry.putBackAvailable {
                let result = try history.putBack(entry.id)
                if !isRestored(result) {
                    reporter.check(false, "\(label): cleanup could not Put Back history entry \(entry.id)")
                    safeToRemoveRoot = false
                }
            }

            let allRecords = try history.records() + history.pendingIntent()
            let pending = try history.pendingIntent()
            if !pending.isEmpty {
                reporter.check(false, "\(label): cleanup retained an intent for an unavailable volume")
                safeToRemoveRoot = false
            }
            let unknownLocations = allRecords.filter { record in
                record.state == .locationUnknown && record.members.contains {
                    $0.trashURL == nil && !FileManager.default.fileExists(atPath: $0.originalURL.path)
                }
            }
            if !unknownLocations.isEmpty {
                reporter.check(false, "\(label): cleanup cannot prove the Trash location for a recovered item")
                safeToRemoveRoot = false
            }
            var removedLeftovers = 0
            for record in allRecords {
                for member in record.members {
                    guard let trashURL = member.trashURL,
                          FileManager.default.fileExists(atPath: trashURL.path) else { continue }
                    guard member.originalURL.path.hasPrefix(root.path + "/"),
                          trashURL.standardizedFileURL != member.originalURL.standardizedFileURL,
                          let expectedTrash = expectedTrashDirectory(for: member.originalURL),
                          trashURL.deletingLastPathComponent().standardizedFileURL
                            == expectedTrash.standardizedFileURL,
                          let live = try? FolderMember.read(at: trashURL),
                          live.volumeKey == record.volumeKey,
                          live.fileID == member.fileID, live.size == member.size,
                          live.modificationDate == member.modificationDate else {
                        reporter.check(false, "\(label): recorded Trash URL failed ownership checks; left untouched")
                        safeToRemoveRoot = false
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: trashURL)
                        removedLeftovers += 1
                        reporter.note("\(label): removed leftover at recorded Trash URL \(trashURL.path)")
                    } catch {
                        reporter.check(false, "\(label): could not remove recorded Trash URL: \(error)")
                        safeToRemoveRoot = false
                    }
                }
            }
            reporter.check(removedLeftovers == 0,
                           "\(label): cleanup found no Trash leftovers after Put Back\(removedLeftovers == 0 ? "" : " (removed \(removedLeftovers) recorded URLs)")")
            let remaining = try (history.records() + history.pendingIntent())
                .flatMap(\.members).compactMap(\.trashURL)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !remaining.isEmpty { safeToRemoveRoot = false }
            reporter.check(remaining.isEmpty,
                           "\(label): every recorded Trash URL is absent at cleanup")
        } catch {
            reporter.check(false, "\(label): cleanup failed while reconciling or reading history: \(error)")
            safeToRemoveRoot = false
        }
        self.safeToRemoveRoot = safeToRemoveRoot

        if removeRoot {
            if safeToRemoveRoot {
                do {
                    try FileManager.default.removeItem(at: root)
                    reporter.check(!FileManager.default.fileExists(atPath: root.path),
                                   "\(label): throwaway root was removed")
                } catch {
                    reporter.check(false, "\(label): could not remove throwaway root: \(error)")
                }
            } else {
                reporter.check(false, "\(label): throwaway root retained at \(root.path) for Trash recovery")
            }
        }
        finished = true
    }

    func removeStartupRoot() {
        guard safeToRemoveRoot else {
            reporter.check(false, "startup: throwaway root retained at \(root.path) for Trash recovery")
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
            reporter.check(!FileManager.default.fileExists(atPath: root.path),
                           "startup: temporary throwaway root was removed after image detach")
        } catch {
            reporter.check(false, "startup: could not remove temporary root \(root.path): \(error)")
        }
        finished = true
    }

    private func createFixtures() throws -> FixtureSet {
        let same = try makeDirectory(fixtureRoot, name: "same-folder")
        let crossLeftDir = try makeDirectory(fixtureRoot, name: "cross-folder-a")
        let crossRightDir = try makeDirectory(fixtureRoot, name: "cross-folder-b")
        let taggedDir = try makeDirectory(fixtureRoot, name: "tagged-pair")
        let grouped = try makeDirectory(fixtureRoot, name: "grouped-items")
        let editedDir = try makeDirectory(fixtureRoot, name: "edited-item")

        let sameKeeper = same.appendingPathComponent("SameKeeper.jpg")
        let sameCopy = same.appendingPathComponent("SameCopy.jpg")
        try writeJPEG(sameKeeper, seed: 17, captureDate: "2020:01:02 03:04:05")
        try FileManager.default.copyItem(at: sameKeeper, to: sameCopy)

        let crossLeft = crossLeftDir.appendingPathComponent("CrossLeft.jpg")
        let crossRight = crossRightDir.appendingPathComponent("CrossRight.jpg")
        try writeJPEG(crossLeft, seed: 39, captureDate: "2020:02:03 04:05:06")
        try FileManager.default.copyItem(at: crossLeft, to: crossRight)

        let taggedFirst = taggedDir.appendingPathComponent("TaggedFirst.jpg")
        let taggedSecond = taggedDir.appendingPathComponent("TaggedSecond.jpg")
        try writeJPEG(taggedFirst, seed: 63, captureDate: "2020:03:04 05:06:07")
        try FileManager.default.copyItem(at: taggedFirst, to: taggedSecond)
        let tagItems = try FolderEnumerator.enumerate(root: taggedDir).items
        guard tagItems.count == 2,
              let currentKeeper = tagItems.first(where: { $0.id == keeper(tagItems.map(\.photo)).uuid }),
              let taggedCandidate = tagItems.first(where: { $0.id != currentKeeper.id }) else {
            throw HarnessError(message: "\(label): could not select the non-keeper Finder-tag fixture")
        }
        try setFinderTag(at: taggedCandidate.primary.url)

        let livePhoto = grouped.appendingPathComponent("LivePhoto.jpg")
        let liveMovie = grouped.appendingPathComponent("LivePhoto.mov")
        try writeJPEG(livePhoto, seed: 82, captureDate: "2020:04:05 06:07:08")
        try Data("Snapsift throwaway Live Photo motion fixture".utf8).write(to: liveMovie)

        let rawJPEG = grouped.appendingPathComponent("RawPhoto.jpg")
        let rawFile = grouped.appendingPathComponent("RawPhoto.dng")
        try writeJPEG(rawJPEG, seed: 104, captureDate: "2020:05:06 07:08:09")
        try Data("Snapsift throwaway fake RAW fixture".utf8).write(to: rawFile)

        let editedPhoto = editedDir.appendingPathComponent("EditedPhoto.jpg")
        let sidecar = editedDir.appendingPathComponent("EditedPhoto.xmp")
        try writeJPEG(editedPhoto, seed: 127, captureDate: "2020:06:07 08:09:10")
        try Data("<x:xmpmeta>throwaway edit sidecar</x:xmpmeta>".utf8).write(to: sidecar)

        return FixtureSet(files: [sameKeeper, sameCopy, crossLeft, crossRight,
                                  taggedFirst, taggedSecond, livePhoto, liveMovie,
                                  rawJPEG, rawFile, editedPhoto, sidecar],
                          sameFolderKeeper: sameKeeper.lastPathComponent,
                          sameFolderCopy: sameCopy.lastPathComponent,
                          crossFolderLeft: crossLeft.lastPathComponent,
                          crossFolderRight: crossRight.lastPathComponent,
                          taggedFilename: taggedCandidate.primary.url.lastPathComponent,
                          livePhotoFilename: livePhoto.lastPathComponent,
                          rawFilename: rawJPEG.lastPathComponent,
                          editedFilename: editedPhoto.lastPathComponent,
                          livePhotoMovieFilename: liveMovie.lastPathComponent,
                          rawFilenameCompanion: rawFile.lastPathComponent,
                          sidecarFilename: sidecar.lastPathComponent,
                          taggedURL: taggedCandidate.primary.url)
    }

    private func assertTrashLocations(_ records: [FolderHistoryRecord], source: URL) throws {
        let expected: URL?
        if isStartupVolume {
            expected = startupTrashDirectory
        } else if let volumeRoot {
            expected = volumeRoot.appendingPathComponent(".Trashes", isDirectory: true)
                .appendingPathComponent(String(getuid()), isDirectory: true)
        } else {
            expected = nil
        }
        let locationsValid = expected.map { trashDirectory in
            records.allSatisfy { record in
                record.volumeKey == volumeKey && record.members.allSatisfy { member in
                    guard let trashURL = member.trashURL else { return false }
                    return trashURL.deletingLastPathComponent().standardizedFileURL
                        == trashDirectory.standardizedFileURL
                        && probeVolume(at: trashURL).volumeKey == record.volumeKey
                }
            }
        } ?? false
        reporter.check(locationsValid,
                       "\(label): every recorded Trash URL is on the source volume in its expected Trash")
        if expected == nil { reporter.note("\(label): expected Trash directory could not be resolved for \(source.path)") }
    }

    private func expectedTrashDirectory(for source: URL) -> URL? {
        if isStartupVolume { return startupTrashDirectory }
        guard let volumeRoot else { return nil }
        return volumeRoot.appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
    }
}

private func isRestored(_ result: FolderPutBackResult) -> Bool {
    if case .restored = result { return true }
    return false
}

private func makeDirectory(_ parent: URL, name: String) throws -> URL {
    let directory = parent.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func writeJPEG(_ url: URL, seed: Int, captureDate: String) throws {
    let width = 512
    let height = 384
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw HarnessError(message: "Could not create ImageIO fixture bitmap")
    }
    let columns = 32
    let rows = 24
    for row in 0..<rows {
        for column in 0..<columns {
            let mixed = (column * 89 + row * 131 + seed * 47) ^ (column * row * 29 + seed * 73)
            let red = CGFloat((mixed & 0xff)) / 255
            let green = CGFloat(((mixed >> 3) & 0xff)) / 255
            let blue = CGFloat(((mixed >> 7) & 0xff)) / 255
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: column * 16, y: row * 16, width: 16, height: 16))
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw HarnessError(message: "Could not create ImageIO JPEG fixture at \(url.path)")
    }
    let properties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.92,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: captureDate,
            kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Snapsift Harness",
            kCGImagePropertyTIFFModel: "Generated Fixture",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw HarnessError(message: "Could not finalize ImageIO JPEG fixture at \(url.path)")
    }
}

private func setFinderTag(at url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["Snapsift Harness\n6"], format: .binary, options: 0)
    let status = url.path.withCString { path in
        "com.apple.metadata:_kMDItemUserTags".withCString { name in
            data.withUnsafeBytes { bytes in
                setxattr(path, name, bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
    }
    guard status == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

@MainActor
private final class DiskImageAttachment {
    private var mountPoint: URL?
    private var attached = false

    func createAndAttach(in root: URL) throws -> URL {
        let token = UUID().uuidString.lowercased()
        let image = root.appendingPathComponent("folder-live-\(token).dmg")
        let mount = root.appendingPathComponent("image-volume-\(token)", isDirectory: true)
        mountPoint = mount
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try runHdiutil(["create", "-size", "128m", "-fs", "APFS",
                        "-volname", "SnapsiftLive\(token.prefix(8))",
                        "-type", "UDIF", image.path])
        try runHdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        attached = true
        return mount
    }

    func detach(reporter: CheckReporter) {
        guard attached, let mountPoint else { return }
        do {
            try runHdiutil(["detach", mountPoint.path])
            attached = false
            reporter.check(true, "disk image: external APFS volume detached")
        } catch {
            do {
                try runHdiutil(["detach", "-force", mountPoint.path])
                attached = false
                reporter.check(true, "disk image: detached with the forced cleanup fallback")
            } catch {
                reporter.check(false, "disk image: could not detach its own mount point: \(error)")
            }
        }
    }

    private func runHdiutil(_ arguments: [String]) throws {
        let executable = URL(fileURLWithPath: "/usr/bin/hdiutil")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HarnessError(message: "hdiutil is unavailable at \(executable.path)")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let captured = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessError(message: "hdiutil \(arguments.first ?? "") failed: \(String(decoding: captured, as: UTF8.self))")
        }
    }
}

@main
private enum SnapsiftFolderLiveTests {
    @MainActor
    static func main() async {
        let reporter = CheckReporter()
        var startup: VolumeRun?
        var external: VolumeRun?
        var diskImage: DiskImageAttachment?

        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
            let startRun = try VolumeRun(label: "startup", parent: temporaryDirectory,
                                        isStartupVolume: true, volumeRoot: nil, reporter: reporter)
            startup = startRun

            let startupProbe = probeVolume(at: startRun.root)
            let homeProbe = probeVolume(at: FileManager.default.homeDirectoryForCurrentUser)
            try expect(startupProbe.volumeKey != nil && startupProbe.volumeKey == homeProbe.volumeKey,
                       "startup: unique throwaway root is under the user's temporary directory on the Data volume",
                       reporter: reporter)
            try expect(startupProbe.facts.isRootFileSystem == true
                       && startupProbe.capability == .removalSupported,
                       "startup: Data volume is writable and classified for real Trash removal",
                       reporter: reporter)

            if let externalPath = options.externalPath {
                do {
                    guard externalPath.hasPrefix("/") else {
                        throw HarnessError(message: "--external requires an absolute mounted-volume path")
                    }
                    let base = URL(fileURLWithPath: externalPath, isDirectory: true)
                        .standardizedFileURL.resolvingSymlinksInPath()
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        throw HarnessError(message: "--external path is not an existing directory: \(base.path)")
                    }
                    let probe = probeVolume(at: base)
                    try expect(probe.volumeKey != nil && probe.volumeKey != startupProbe.volumeKey,
                               "external: supplied path is on a volume distinct from startup Data",
                               reporter: reporter)
                    try expect(probe.facts.isRootFileSystem == false
                               && probe.capability == .removalSupported && probe.volumeURL != nil,
                               "external: mounted volume is writable, local, and positively Trash-capable",
                               reporter: reporter)
                    external = try VolumeRun(label: "external", parent: base,
                                             isStartupVolume: false, volumeRoot: probe.volumeURL,
                                             reporter: reporter)
                } catch {
                    reporter.check(false, "external: setup failed: \(error)")
                }
            } else if options.makeImage {
                do {
                    let image = DiskImageAttachment()
                    diskImage = image
                    let mount = try image.createAndAttach(in: startRun.root)
                    let probe = probeVolume(at: mount)
                    try expect(probe.volumeKey != nil && probe.volumeKey != startupProbe.volumeKey,
                               "disk image: attached APFS volume is distinct from startup Data",
                               reporter: reporter)
                    try expect(probe.facts.isRootFileSystem == false
                               && probe.capability == .removalSupported && probe.volumeURL != nil,
                               "disk image: attached APFS volume is writable and Trash-capable",
                               reporter: reporter)
                    external = try VolumeRun(label: "external APFS image", parent: mount,
                                             isStartupVolume: false, volumeRoot: probe.volumeURL,
                                             reporter: reporter)
                } catch {
                    reporter.check(false, "disk image: setup failed: \(error)")
                }
            }

            for run in [startRun, external].compactMap({ $0 }) {
                do { try await run.exercise() }
                catch { reporter.check(false, "\(run.label): harness stopped: \(error)") }
            }
        } catch {
            reporter.check(false, "Harness setup failed: \(error)")
        }

        external?.cleanup(removeRoot: true)
        startup?.cleanup(removeRoot: false)
        if let diskImage { diskImage.detach(reporter: reporter) }
        startup?.removeStartupRoot()

        reporter.printTable()
        exit(reporter.failures == 0 ? 0 : 1)
    }
}
