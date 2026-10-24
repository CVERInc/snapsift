import Foundation
import SnapsiftCore
@testable import SnapsiftFolder

/// One volume with an unconfirmed app folder and a confirmed File Provider
/// storage folder. Every pre-marked copy is a two-member pair, and every live
/// location read behind `canReviewRemoval` is counted.
@MainActor
private final class RemovalProbeFixture {
    let root: URL
    let confirmed: URL
    let unconfirmed: URL
    let volumeKey: VolumeKey?
    var items: [FolderItem] = []
    var groups: [ReviewGroup] = []
    var status: FolderLocationGrantStatus = .notAsked
    var volumeProbes = 0
    var locationReads = 0

    init(groupsPerFolder: Int) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-removal-probe-\(UUID())")
        confirmed = root.appendingPathComponent("Containers/Shared/AppGroup/fixture/File Provider Storage/picked")
        unconfirmed = root.appendingPathComponent("Containers/Data/Application/fixture/Documents")
        for folder in [unconfirmed, confirmed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<groupsPerFolder {
                var pair: [FolderItem] = []
                for name in ["keeper", "candidate"] {
                    let url = folder.appendingPathComponent("\(index)-\(name).jpg")
                    try Data("\(folder.lastPathComponent) \(index)-\(name)".utf8).write(to: url)
                    let member = try FolderMember.read(at: url)
                    var members = [member]
                    if name == "candidate" {
                        let movie = folder.appendingPathComponent("\(index)-\(name).mov")
                        try Data("motion".utf8).write(to: movie)
                        members.append(try FolderMember.read(at: movie))
                    }
                    let photo = Photo(uuid: url.path, filename: url.lastPathComponent, takenAt: Double(index),
                                      width: 16, height: 16, size: member.size, uti: "public.jpeg")
                    pair.append(FolderItem(photo: photo, primary: member, members: members,
                                           directoryURL: folder, folderKey: folder.path))
                }
                var group = ReviewGroup(photos: pair.map(\.photo), keeperID: pair[0].id)
                group.rejected = [pair[1].id]
                items += pair
                groups.append(group)
            }
        }
        volumeKey = probeVolume(at: root).volumeKey
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func facts(_ url: URL) -> VolumeFacts {
        VolumeFacts(isLocal: true, isReadOnly: false, mntRdOnly: false,
                    fileSystemType: "apfs", isRootFileSystem: false, path: url.path)
    }
    func probe(_ url: URL) -> VolumeProbeResult {
        volumeProbes += 1
        return VolumeProbeResult(facts: facts(url), volumeKey: volumeKey, displayName: "Fixture",
                                 volumeURL: nil, capability: classifyTrashLocation(facts(url)))
    }
    var grants: FolderLocationGrants {
        FolderLocationGrants(status: { _ in self.status }, access: { _ in nil })
    }
    var port: FolderTrashPort {
        FolderTrashPort.confirmedLocation(trash: { _ in nil }, locationFacts: { url in
            self.locationReads += 1
            return self.facts(url)
        })
    }

    func session(_ folders: [URL]) throws -> FolderLibrarySession {
        let bookmarks = FolderBookmarkStore(url: root.appendingPathComponent("bookmarks-\(UUID()).json"),
            makeAccess: { try FolderAccess(url: $0, startAccess: { _ in true }, stopAccess: { _ in }) },
            resolveBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
        try FolderHistoryStore.atomicWrite(JSONEncoder().encode(folders.map {
            FolderBookmark(data: Data($0.path.utf8))
        }), bookmarks.url)
        let store = FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                                       intentURL: root.appendingPathComponent("intent.json"))
        let scanned = items.filter { folders.contains($0.directoryURL) }
        let ids = Set(scanned.map(\.id))
        let scannedGroups = groups.filter { $0.photos.allSatisfy { ids.contains($0.uuid) } }
        return FolderLibrarySession(bookmarks: bookmarks, history: store, trashPort: port, grants: grants,
            volumeProbe: probe, scan: { roots in
                FolderScanResult(items: scanned, groups: scannedGroups, exactGroupIDs: [], crossFolderDuplicates: [],
                    roots: roots.map { FolderScannedRoot(url: $0, volume: self.probe($0)) },
                    issues: [], primaryHashes: [:], uniqueMetadataWithheld: 0, uniqueMetadataIDs: [], knownCarryingIDs: [], undeterminedIDs: [],
                    imageProvider: FolderImageProvider(items: scanned), accesses: [])
            }, metadata: { _ in [:] })
    }

    func scan(_ session: FolderLibrarySession) async {
        session.loadFolders()
        session.startScan()
        for _ in 0..<10_000 {
            if !session.isScanning { break }
            await Task.yield()
        }
    }

    func evaluate(_ session: FolderLibrarySession) -> (removable: Bool, probes: Int, reads: Int) {
        volumeProbes = 0
        locationReads = 0
        let removable = session.canReviewRemoval
        return (removable, volumeProbes, locationReads)
    }

    /// The probe-first formula `canReviewRemoval` used before roots were checked first.
    func reference(_ session: FolderLibrarySession) -> Bool {
        guard !session.isScanning, !session.isBusy, !session.showHistory, let result = session.result else { return false }
        let supported = result.roots.filter { $0.volume.capability == .removalSupported }
        let port = port, grants = grants
        return session.groups.contains { group in
            group.deletionIDs.contains { id in
                guard let item = session.item(for: id) else { return false }
                return item.members.allSatisfy { member in
                    port.capability(probe(member.url), at: member.url, grants: grants) == .removalSupported
                    && supported.contains { root in
                        let path = folderLocationComponents(member.url)
                        let rootPath = folderLocationComponents(root.url)
                        return root.volume.volumeKey == member.volumeKey
                            && path.count > rootPath.count && path.starts(with: rootPath)
                    }
                }
            }
        }
    }
}

@MainActor
func folderRemovalProbeTests(_ check: (Bool, String) -> Void) async {
    print("Removal eligibility checks scan roots before live location probes")
    do {
        let f = try RemovalProbeFixture(groupsPerFolder: 12)
        defer { f.cleanup() }

        let scanOnly = try f.session([f.unconfirmed])
        await f.scan(scanOnly)
        let a = f.evaluate(scanOnly)
        check(scanOnly.hasScanned && scanOnly.totalDeletions == 12
              && scanOnly.result?.roots.allSatisfy({ $0.volume.capability != .removalSupported }) == true
              && !a.removable && a.probes == 0 && a.reads == 0,
              "pre-marks under only scan-only roots are not removable and cost no location probe: \(a)")
        check(a.removable == f.reference(scanOnly), "scan-only eligibility matches the probe-first formula")

        let mixed = try f.session([f.unconfirmed, f.confirmed])
        await f.scan(mixed)
        f.status = .declined
        let b = f.evaluate(mixed)
        check(mixed.totalDeletions == 24
              && mixed.result?.roots.filter({ $0.volume.capability == .removalSupported }).count == 1
              && !b.removable && b.probes == 12 && b.reads == 12,
              "a declined grant before root refresh probes each confirmed pre-mark once and no scan-only member: \(b)")
        check(b.removable == f.reference(mixed), "declined-grant eligibility matches the probe-first formula")

        mixed.refreshLocationCapabilities()
        let refreshed = f.evaluate(mixed)
        check(mixed.result?.roots.allSatisfy({ $0.volume.capability != .removalSupported }) == true
              && !refreshed.removable && refreshed.probes == 0 && refreshed.reads == 0,
              "a refreshed declined root is skipped without location probes: \(refreshed)")
        check(refreshed.removable == f.reference(mixed), "refreshed declined eligibility matches the probe-first formula")

        f.status = .granted
        mixed.refreshLocationCapabilities()
        let c = f.evaluate(mixed)
        check(c.removable && c.probes == 2 && c.reads == 2,
              "the first removable pre-mark still authorizes review after probing only its own members: \(c)")
        check(c.removable == f.reference(mixed), "granted eligibility matches the probe-first formula")
    } catch { check(false, "removal probe fixture: \(error)") }
}
