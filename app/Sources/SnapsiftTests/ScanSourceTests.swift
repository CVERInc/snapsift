import Foundation
import Photos
import SnapsiftCore
@testable import SnapsiftPhotoKit

// Pure predicate/codec checks and the empty-source session gate. No Photos
// library is read, no authorization is requested, and no images are decoded.
@MainActor
func checkScanSources() async {
    print("Photos scan sources: date bounds, caller options and frozen snapshots")
    checkCaptureDateOptions()
    checkScanSourceSnapshots()
    await checkEmptyScanSource()
}

@MainActor
private func checkCaptureDateOptions() {
    let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 812_345_600.125), duration: 5.5)
    let options = PHFetchOptions()
    let media = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.predicate = media
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.includeHiddenAssets = true
    options.includeAllBurstAssets = true
    options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
    options.fetchLimit = 123
    options.wantsIncrementalChangeDetails = false
    let scoped = captureDateFetchOptions(interval: interval, options: options)
    check(scoped !== options && options.predicate === media,
          "date bounds copy options without mutating the caller's predicate")
    check(scoped.sortDescriptors == options.sortDescriptors
          && scoped.includeHiddenAssets == options.includeHiddenAssets
          && scoped.includeAllBurstAssets == options.includeAllBurstAssets
          && scoped.includeAssetSourceTypes == options.includeAssetSourceTypes
          && scoped.fetchLimit == options.fetchLimit
          && scoped.wantsIncrementalChangeDetails == options.wantsIncrementalChangeDetails,
          "date options preserve sort, hidden, bursts, asset sources, limit and change details")
    let compound = scoped.predicate as? NSCompoundPredicate
    check(compound?.compoundPredicateType == .and && compound?.subpredicates.count == 2
          && (compound?.subpredicates.first as? NSPredicate) == media,
          "date bounds AND the caller's original filter")
    func matches(_ predicate: NSPredicate?, _ date: Date?, mediaType: PHAssetMediaType = .image) -> Bool {
        var asset: [String: Any] = ["mediaType": mediaType.rawValue]
        if let date { asset["creationDate"] = date }
        return predicate?.evaluate(with: asset) ?? false
    }
    check(!matches(scoped.predicate, interval.start.addingTimeInterval(-0.001))
          && matches(scoped.predicate, interval.start)
          && matches(scoped.predicate, interval.end.addingTimeInterval(-0.001))
          && !matches(scoped.predicate, interval.end)
          && !matches(scoped.predicate, interval.end.addingTimeInterval(0.001)),
          "capture-date interval includes the start and excludes the end")
    check(!matches(scoped.predicate, interval.start, mediaType: .video),
          "in-range videos remain excluded by the caller's media-type filter")
    check(!matches(scoped.predicate, nil)
          && scoped.predicate?.evaluate(with: ["creationDate": NSNull(), "mediaType": 1]) == false,
          "assets with missing or nil creation dates never match a date interval")

    let unfiltered = PHFetchOptions()
    let dateOnly = captureDateFetchOptions(interval: interval, options: unfiltered)
    check(unfiltered.predicate == nil && (dateOnly.predicate as? NSCompoundPredicate)?.subpredicates.count == 1
          && matches(dateOnly.predicate, interval.start, mediaType: .video)
          && !matches(dateOnly.predicate, interval.end)
          && !matches(dateOnly.predicate, nil),
          "nil caller predicate adds only the half-open date bound")
    let empty = captureDateFetchOptions(interval: DateInterval(start: interval.start, duration: 0), options: unfiltered)
    check(!matches(empty.predicate, interval.start), "zero-duration date intervals match nothing")

    let album = AlbumItem(id: "fixture-album", title: "Fixture", estimatedCount: 2)
    for source in [ScanSource.wholeLibrary, .album(album), .identifiers(["last", "first", "last"])] {
        let unlimited = ScanFetchRequest(source: source, captureDates: nil, options: options)
        check(unlimited?.source == source && unlimited?.options === options,
              "every source passes the caller's options through unchanged without dates: \(source)")
        guard let bounded = ScanFetchRequest(source: source, captureDates: interval, options: options) else {
            check(false, "a date bound leaves the source resolvable: \(source)")
            continue
        }
        check(bounded.source == source && bounded.options !== options && options.predicate === media
              && bounded.options.predicate == scoped.predicate
              && bounded.options.sortDescriptors == options.sortDescriptors
              && bounded.options.includeHiddenAssets == options.includeHiddenAssets
              && bounded.options.includeAllBurstAssets == options.includeAllBurstAssets
              && bounded.options.includeAssetSourceTypes == options.includeAssetSourceTypes
              && bounded.options.fetchLimit == options.fetchLimit
              && bounded.options.wantsIncrementalChangeDetails == options.wantsIncrementalChangeDetails,
              "every source composes dates while preserving all caller options: \(source)")
        check(matches(bounded.options.predicate, interval.start)
              && !matches(bounded.options.predicate, interval.end)
              && !matches(bounded.options.predicate, nil)
              && !matches(bounded.options.predicate, interval.start, mediaType: .video),
              "every source applies the same half-open, dated-only and media filters: \(source)")
        check(ScanFetchRequest(source: source,
                  captureDates: DateInterval(start: interval.start, duration: 0), options: options) != nil,
              "a date bound matching nothing is a valid fetch for every source: \(source)")
    }

    for kind in [PhotoLibrarySession.ScanKind.burst, .lookAlikes, .similarSets] {
        let photos = PhotoLibrarySession.scanFetchOptions(for: kind, includeVideo: false)
        let videos = PhotoLibrarySession.scanFetchOptions(for: kind, includeVideo: true)
        check(photos.includeAllBurstAssets == (kind == .burst)
              && photos.sortDescriptors?.first?.ascending == (kind != .similarSets)
              && !photos.includeHiddenAssets && photos.predicate == media
              && videos.predicate == nil && videos.includeAllBurstAssets == photos.includeAllBurstAssets,
              "count and scan share the existing \(kind.rawValue) options for either videos setting")
    }
}

/// The exact schema-1 shape: no structured source or capture-date field.
private struct LegacyScopeSnapshot: Encodable {
    let schema = 1
    let kind = "burst"
    let sourceID: String?
    let timestamp = Date(timeIntervalSinceReferenceDate: 100)
    let changeToken: Data? = nil
    let groups: [ScanSnapshot.Group] = [
        .init(photos: [ph(1, 0), ph(2, 1)], keeperID: "U1", rejected: [], autoSeeded: [],
              confidentDupe: false, exact: false)
    ]
    let categories: [ScanSnapshot.Category] = []
}

@MainActor
private func checkScanSourceSnapshots() {
    let album = AlbumItem(id: "fixture-album", title: "Fixture", estimatedCount: 2)
    let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 812_345_600.125),
                                end: Date(timeIntervalSinceReferenceDate: 812_400_000.875))
    let sources: [ScanSource] = [.wholeLibrary, .album(album),
                                  .identifiers(["last", "first", "last"]), .identifiers([])]
    let nextDates = DateInterval(start: interval.end, duration: 60)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/scan-source-tests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = PhotoLibraryStorage(directory: root)
    let store = ScanSnapshotStore(url: storage.snapshotURL)
    func makeSession() -> PhotoLibrarySession {
        PhotoLibrarySession(storage: storage, albumTitles: testAlbumTitles(),
                            imageManager: ScopeTestImageManager())
    }
    // Supply the live facts directly; the session's publication step is the
    // same one used after a public restore resolves assets from Photos.
    func restore(_ snapshot: ScanSnapshot, into session: PhotoLibrarySession,
                 albums: [AlbumItem]) -> Bool {
        let restored = snapshot.restored(liveFavorites: ["U1": false, "U2": false],
                                         editedNow: [:], tokenCurrent: true)
        return session.applyRestoredSnapshot(snapshot, restored: restored, assetsByID: [:],
                                             albums: albums, tokenCurrent: true)
    }
    do {
        for source in sources {
            for captureDates in [nil, interval] as [DateInterval?] {
                let saved = ScanSnapshot.Source(source)
                let snapshot = ScanSnapshot(kind: "burst", sourceID: saved.albumID, source: saved,
                    captureDates: captureDates,
                    timestamp: Date(), changeToken: nil, groups: LegacyScopeSnapshot(sourceID: nil).groups,
                    categories: [])
                let encoded = try JSONEncoder().encode(snapshot)
                let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: encoded)
                check(decoded.schema == 2 && decoded.source == saved
                      && decoded.restoredSource(albums: [album]) == source
                      && decoded.restoredCaptureDates == captureDates,
                      "source and separate date bound round-trip exactly: \(saved), \(String(describing: captureDates))")
                let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                let dates = object?["captureDates"] as? [String: Any]
                check(object?["source"] != nil
                      && (captureDates == nil ? object?["captureDates"] == nil
                          : (dates?["start"] as? Double == captureDates?.start.timeIntervalSinceReferenceDate
                             && dates?["end"] as? Double == captureDates?.end.timeIntervalSinceReferenceDate)),
                      "schema 2 stores a source plus optional exact start/end fields")
                check(store.saveSync(snapshot) && store.load()?.restoredSource(albums: [album]) == source
                      && store.load()?.restoredCaptureDates == captureDates,
                      "snapshot store accepts every source/date combination")
                let session = makeSession()
                session.scanCaptureDates = nextDates
                guard let stored = store.load() else {
                    check(false, "review-scope fixture loads its snapshot")
                    continue
                }
                check(session.reviewSource == nil && session.reviewCaptureDates == nil
                      && restore(stored, into: session, albums: [album])
                      && session.hasScanned && session.reviewSource == source && session.scanSource == source
                      && session.reviewCaptureDates == captureDates && session.scanCaptureDates == captureDates,
                      "session restores both review and next-scan scope: \(saved)")
                session.scanSource = .identifiers(["next-scan"])
                session.scanCaptureDates = nextDates
                check(session.reviewSource == source && session.reviewCaptureDates == captureDates,
                      "changing both next-scan choices leaves the restored review scope frozen")
                session.flushSnapshotSync()
                check(store.load()?.savedSource == saved && store.load()?.restoredCaptureDates == captureDates,
                      "saving review decisions retains the frozen source and dates after next-scan changes")
                if source.albumItem != nil {
                    let renamed = AlbumItem(id: album.id, title: "Renamed", estimatedCount: 5)
                    check(restore(stored, into: session, albums: [renamed])
                          && session.reviewSource == .album(renamed) && session.scanSource == .album(renamed)
                          && session.reviewCaptureDates == captureDates && session.scanCaptureDates == captureDates,
                          "restored scopes prefer current album metadata and keep frozen dates")
                    let nextSource = ScanSource.identifiers(["next-scan"])
                    session.scanSource = nextSource
                    session.scanCaptureDates = nextDates
                    let missing = AlbumItem(id: album.id, title: album.title, estimatedCount: -1)
                    check(restore(stored, into: session, albums: [])
                          && session.reviewSource == .album(missing) && session.scanSource == nextSource
                          && session.reviewCaptureDates == captureDates && session.scanCaptureDates == nextDates,
                          "missing album retains its frozen review scope without changing either next-scan choice")
                    let untitled = ScanSnapshot(kind: "burst", sourceID: album.id,
                        source: .album(id: album.id, title: nil), captureDates: captureDates,
                        timestamp: Date(), changeToken: nil,
                        groups: snapshot.groups, categories: [])
                    check(restore(untitled, into: session, albums: [])
                          && session.reviewSource == .album(AlbumItem(id: album.id, title: "", estimatedCount: -1))
                          && session.scanSource == nextSource && session.reviewCaptureDates == captureDates
                          && session.scanCaptureDates == nextDates,
                          "an unknown saved album title restores as empty with an unknown count")
                }
                if source.albumItem == nil {
                    check(source.displayTitle.isEmpty && decoded.restoredSource(albums: []) == source,
                          "non-album sources need no album resolution and leave titles to the caller")
                }
            }
        }
        for sourceID in [album.id, nil] {
            let encoded = try JSONEncoder().encode(LegacyScopeSnapshot(sourceID: sourceID))
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: encoded)
            let expected: ScanSource = sourceID == nil ? .wholeLibrary : .album(album)
            check(object?["source"] == nil && object?["captureDates"] == nil
                  && decoded.source == nil && decoded.restoredCaptureDates == nil
                  && decoded.restoredSource(albums: [album]) == expected,
                  "legacy schema-1 \(sourceID == nil ? "whole-library" : "album") source restores unchanged")
            try encoded.write(to: store.url, options: .atomic)
            check(store.load()?.restoredSource(albums: [album]) == expected,
                  "snapshot store still loads bytes encoded in the old schema")
            let session = makeSession()
            session.scanCaptureDates = nextDates
            check(restore(decoded, into: session, albums: [album]) && session.reviewSource == expected
                  && session.scanSource == expected && session.reviewCaptureDates == nil
                  && session.scanCaptureDates == nil,
                  "legacy snapshot restores both scopes with no date bound")
            if sourceID != nil {
                check(decoded.restoredSource(albums: []) == nil,
                      "missing legacy album leaves the next-scan selection unchanged")
                let renamed = AlbumItem(id: album.id, title: "Renamed", estimatedCount: 5)
                check(decoded.restoredSource(albums: [renamed]) == .album(renamed),
                      "legacy album restore uses current album metadata")
                let nextSource = ScanSource.identifiers(["next-scan"])
                session.scanSource = nextSource
                session.scanCaptureDates = nextDates
                check(restore(decoded, into: session, albums: [])
                      && session.reviewSource == .album(AlbumItem(id: album.id, title: "", estimatedCount: -1))
                      && session.scanSource == nextSource && session.scanCaptureDates == nextDates
                      && session.reviewCaptureDates == nil,
                      "missing legacy album restores its id with unknown metadata and preserves the next scan")
            }
        }
    } catch { check(false, "scan-source snapshot fixtures: \(error)") }
}

private final class ScopeTestImageManager: PHCachingImageManager, @unchecked Sendable {}

@MainActor
private func checkEmptyScanSource() async {
    let options = PHFetchOptions()
    let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 812_345_600.125), duration: 5.5)
    for captureDates in [nil, interval] as [DateInterval?] {
        check(ScanFetchRequest(source: .identifiers([]), captureDates: captureDates, options: options) == nil
              && fetchAssets(source: .identifiers([]), captureDates: captureDates, options: options) == nil
              && countAssets(source: .identifiers([]), captureDates: captureDates, options: options) == nil,
              "empty identifier sources with or without dates have no fetch or count, without accessing Photos")
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/empty-scan-source-tests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = PhotoLibrarySession(storage: PhotoLibraryStorage(directory: root),
        albumTitles: testAlbumTitles(), imageManager: ScopeTestImageManager())
    check(session.reviewSource == nil && session.reviewCaptureDates == nil
          && session.scanCaptureDates == nil && !session.hasScanned,
          "a new session has no review scope and defaults to unlimited capture dates")
    let restored = await session.restoreSnapshot()
    check(!restored && session.reviewSource == nil && session.reviewCaptureDates == nil,
          "a session with nothing to restore keeps its review scope nil")
    let priorSource = ScanSource.identifiers(["U1", "U2"])
    let snapshot = ScanSnapshot(kind: "burst", sourceID: nil, source: ScanSnapshot.Source(priorSource),
        captureDates: interval, timestamp: Date(), changeToken: nil,
        groups: LegacyScopeSnapshot(sourceID: nil).groups, categories: [])
    let prior = snapshot.restored(liveFavorites: ["U1": false, "U2": false], editedNow: [:], tokenCurrent: true)
    check(session.applyRestoredSnapshot(snapshot, restored: prior, assetsByID: [:], albums: [], tokenCurrent: true),
          "empty-source gate fixture starts with a frozen review source and date bound")
    for kind in [PhotoLibrarySession.ScanKind.burst, .lookAlikes, .similarSets] {
        for captureDates in [nil, interval] as [DateInterval?] {
            session.scanSource = .identifiers([])
            session.scanCaptureDates = captureDates
            check(session.count(for: session.scanSource, captureDates: captureDates, kind: kind) == nil,
                  "session count handles an empty \(kind.rawValue) source with or without dates")
            session.startScan(kind)
            // Changing the next scan's selection before the task starts must not
            // change this fetch (whole-library fetching would access real Photos).
            session.scanSource = .wholeLibrary
            session.scanCaptureDates = DateInterval(start: interval.end, duration: 60)
            let deadline = Date().addingTimeInterval(5)
            while session.isScanning && Date() < deadline { await Task.yield() }
            check(!session.isScanning && session.groups.count == 1 && session.scanNotice == .albumGone
                  && session.reviewSource == priorSource && session.reviewCaptureDates == interval,
                  "empty \(kind.rawValue) scope with or without dates keeps the prior review scope and albumGone notice")
        }
    }
}
