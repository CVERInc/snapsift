import Foundation
import CoreGraphics
import ImageIO
import SnapsiftCore
import SnapsiftFolder
import SnapsiftVision

private enum FolderGoldenError: Error { case image }

/// Deliberately self-contained: this file also runs unchanged on f84c952.
private func writeCombinedGoldenImage(_ url: URL, scene: UInt64, seconds: Int,
                                       variant: Bool = false, camera: Bool = false) throws {
    let width = 640, height = 480
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FolderGoldenError.image }
    var random = scene
    for row in 0..<8 {
        for column in 0..<9 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let light = CGFloat((random >> 32) % 200 + 28) / 255
            context.setFillColor(red: light, green: light * 0.8, blue: 1 - light * 0.6, alpha: 1)
            context.fill(CGRect(x: Double(column) * Double(width) / 9, y: Double(row * height) / 8,
                                width: Double(width) / 9 + 1, height: Double(height) / 8 + 1))
        }
    }
    if variant {
        context.setFillColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)
        context.fillEllipse(in: CGRect(x: 20, y: 20, width: 2, height: 2))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(seconds))),
        kCGImagePropertyExifOffsetTimeOriginal: "+00:00"
    ]]
    if camera { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Fixture", kCGImagePropertyTIFFModel: "Golden"] }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw FolderGoldenError.image }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FolderGoldenError.image }
}

/// Exact copies tie on every rank signal, including EXIF time. Assign names in
/// inode-key order so the largest UUID always names the last copy, on any volume.
/// Renaming preserves the inode; no generated UUID/inode enters the signature.
private func nameCombinedGoldenCopies(_ urls: [URL], prefix: String) throws {
    let ordered = try urls.map { (url: $0, key: "\(try FolderMember.read(at: $0).fileID):") }
        .sorted { $0.key < $1.key }
    for (index, file) in ordered.enumerated() {
        let suffix = ["a", "b", "c"][index]
        try FileManager.default.moveItem(at: file.url,
            to: file.url.deletingLastPathComponent().appendingPathComponent("\(prefix)-\(suffix).png"))
    }
}

@MainActor
func checkFolderCombinedGolden() async {
    print("Folder combined scan golden (base-compatible real-file fixture)")
    guard visionInferenceAvailable else {
        checkNeedsVision(false, "folder combined golden: skipped: Vision unavailable")
        return
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-golden-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        for directory in [a, b] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // An isolated same-folder pair is needed to exercise seeding: the other
        // triple's cross-folder copy withholds marks from its entire byte bucket.
        let exact = [a.appendingPathComponent("tmp-exact-1.png"), a.appendingPathComponent("tmp-exact-2.png")]
        try writeCombinedGoldenImage(exact[0], scene: 11, seconds: 0)
        try FileManager.default.copyItem(at: exact[0], to: exact[1])
        try nameCombinedGoldenCopies(exact, prefix: "exact")
        let cross = [a.appendingPathComponent("tmp-cross-1.png"), a.appendingPathComponent("tmp-cross-2.png"),
                     b.appendingPathComponent("tmp-cross-3.png")]
        try writeCombinedGoldenImage(cross[0], scene: 29, seconds: 3_600)
        for url in cross.dropFirst() { try FileManager.default.copyItem(at: cross[0], to: url) }
        try nameCombinedGoldenCopies(cross, prefix: "cross")
        try writeCombinedGoldenImage(a.appendingPathComponent("burst-a.png"), scene: 47, seconds: 7_200, camera: true)
        try writeCombinedGoldenImage(a.appendingPathComponent("burst-b.png"), scene: 47, seconds: 7_201, variant: true)
        try writeCombinedGoldenImage(a.appendingPathComponent("near-a.png"), scene: 83, seconds: 10_800, camera: true)
        try writeCombinedGoldenImage(a.appendingPathComponent("near-b.png"), scene: 83, seconds: 97_200, variant: true)
        try writeCombinedGoldenImage(a.appendingPathComponent("single.png"), scene: 131, seconds: 180_000)

        let bookmarksURL = root.appendingPathComponent("folders.json")
        try JSONEncoder().encode([FolderBookmark(data: Data("A".utf8)), FolderBookmark(data: Data("B".utf8))]).write(to: bookmarksURL)
        let session = FolderLibrarySession(
            bookmarks: FolderBookmarkStore(url: bookmarksURL, resolveBookmark: { data in
                (root.appendingPathComponent(String(decoding: data, as: UTF8.self)), false)
            }),
            history: FolderHistoryStore(historyURL: root.appendingPathComponent("history.json"),
                                        intentURL: root.appendingPathComponent("intent.json")))
        session.loadFolders()
        session.startScan() // Default real combined pipeline, including session folderReviewGroups.
        while session.isScanning { await Task.yield() }
        guard let result = session.result else {
            check(false, "folder combined golden: no scan result: \(String(describing: session.errorOutcome))")
            return
        }
        let names = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, $0.photo.filename) })
        func list(_ ids: some Sequence<String>) -> String { ids.map { names[$0] ?? "MISSING:\($0)" }.sorted().joined(separator: ",") }
        let groupLines = session.groups.map { group in
            let files = list(group.photos.map(\.uuid))
            return (files, "\(files) | keeper=\(names[group.keeperID] ?? "MISSING") | rejected=\(list(group.rejected)) | autoSeeded=\(list(group.autoSeeded)) | confidentDupe=\(group.confidentDupe) | exact=\(result.exactGroupIDs.contains(group.id))")
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let crossLines = session.crossFolderMatches.map { "cross=\(list($0))" }.sorted()
        let actual = (groupLines + crossLines).joined(separator: "\n")
        // Analytical expectation; the caller validates this literal on real Vision
        // at both revisions. Any mismatch prints the entire candidate signature.
        let expected = """
        burst-a.png,burst-b.png | keeper=burst-a.png | rejected= | autoSeeded= | confidentDupe=true | exact=false
        cross-a.png,cross-b.png,cross-c.png | keeper=cross-c.png | rejected= | autoSeeded= | confidentDupe=true | exact=true
        exact-a.png,exact-b.png | keeper=exact-b.png | rejected=exact-a.png | autoSeeded=exact-a.png | confidentDupe=true | exact=true
        near-a.png,near-b.png | keeper=near-a.png | rejected= | autoSeeded= | confidentDupe=false | exact=false
        cross=cross-a.png,cross-b.png,cross-c.png
        """
        if actual != expected { print("Folder combined golden actual signature:\n\(actual)\nEnd folder combined golden signature") }
        check(result.items.count == 10, "folder combined golden: every real fixture file was read")
        check(actual == expected, "folder combined golden: groups, keeper, marks, confidence, exact and cross-folder facts")
        session.discardResult()
    } catch { check(false, "folder combined golden fixture: \(error)") }
}
