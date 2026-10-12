import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore
@testable import SnapsiftFolder
import SnapsiftVision

private func writeCloudFixture(_ url: URL) throws {
    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// The local test filesystem cannot supply iCloud residency. File identities,
/// modification dates, enumeration and image/hash reads still use real files.
private final class FakeFolderUbiquity: @unchecked Sendable {
    private let lock = NSLock()
    private var cloud: Set<URL> = []
    private var missing: Set<URL> = []
    private var unknown: Set<URL> = []
    private var stale: Set<URL> = []
    private var starts: [URL] = []
    private var evictions: [URL] = []
    var downloadSucceeds = true
    var evictionFailure: URL?
    var placeholderTarget: URL?

    func setCloud(_ urls: Set<URL>, missing: Set<URL> = [], unknown: Set<URL> = [], stale: Set<URL> = []) {
        lock.lock(); defer { lock.unlock() }
        cloud = urls; self.missing = missing; self.unknown = unknown; self.stale = stale
    }
    var downloadCalls: [URL] { lock.lock(); defer { lock.unlock() }; return starts }
    var evictionCalls: [URL] { lock.lock(); defer { lock.unlock() }; return evictions }
    var port: FolderUbiquityPort {
        FolderUbiquityPort(state: { url in
            self.lock.lock(); defer { self.lock.unlock() }
            let status: URLUbiquitousItemDownloadingStatus? = self.unknown.contains(url) ? nil
                : self.missing.contains(url) ? .notDownloaded : self.stale.contains(url) ? .downloaded : .current
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return FolderUbiquityState(isUbiquitousItem: self.cloud.contains(url), downloadingStatus: status,
                                       fileSize: size)
        }, startDownload: { url in
            self.lock.lock(); defer { self.lock.unlock() }
            self.starts.append(url)
            guard self.downloadSucceeds else { return }
            if url == self.placeholderTarget { try writeCloudFixture(url) }
            self.missing.remove(url)
            self.unknown.remove(url)
        }, evict: { member in
            self.lock.lock(); defer { self.lock.unlock() }
            if member.url == self.evictionFailure { throw CocoaError(.fileWriteNoPermission) }
            self.evictions.append(member.url)
            self.missing.insert(member.url) // Simulate eviction without deleting ANY fixture.
        })
    }
}

@MainActor
func checkFolderICloudPolicy() async {
    print("Folder iCloud policy, accounting and guarded eviction")
    await checkFolderICloudGates()
    guard UTType.png.conforms(to: .image) else {
        print("  Not verified: Folder pipeline integration requires the LaunchServices UTType registry (unavailable in this sandbox)")
        return
    }
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-folder-cloud-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) } // Fixture cleanup, never the eviction path.
        let local = root.appendingPathComponent("local.png")
        let remote = root.appendingPathComponent("remote.png")
        let paired = root.appendingPathComponent("paired.png")
        let sidecar = root.appendingPathComponent("paired.xmp")
        let placeholder = root.appendingPathComponent(".placeholder.png.icloud")
        let logical = root.appendingPathComponent("placeholder.png")
        let ordinaryHidden = root.appendingPathComponent(".ordinary.png.icloud")
        for url in [local, remote, paired] { try writeCloudFixture(url) }
        for url in [sidecar, placeholder, ordinaryHidden] { try Data("metadata".utf8).write(to: url) }
        let fake = FakeFolderUbiquity()
        fake.placeholderTarget = logical
        let cloud: Set<URL> = [remote, sidecar, placeholder, logical]
        fake.setCloud(cloud, missing: cloud)
        var options = FolderScanOptions()
        options.iCloudDownloadPolicy = .localOnly
        let skipped = try await FolderScanPipeline.scan(roots: [root], options: options, ubiquityPort: fake.port)
        defer { skipped.accesses.forEach { $0.stop() } }
        check(skipped.items.map(\.primary.url) == [local] && skipped.downloadedURLs.isEmpty
              && fake.downloadCalls.isEmpty,
              "Folder localOnly: cloud-only images and companions are skipped without requesting downloads")
        check(Set(skipped.issues.filter { $0.reason == .notOnDevice }.map(\.url)) == [remote, sidecar, logical],
              "Folder localOnly: distinct notOnDevice reason includes logical URLs for .icloud placeholders")
        check(!skipped.issues.contains { $0.url == ordinaryHidden },
              "Folder enumeration: ordinary hidden .icloud names stay ignored unless ubiquity is confirmed")

        let downloaded = try await FolderScanPipeline.scan(roots: [root, root], ubiquityPort: fake.port)
        defer { downloaded.accesses.forEach { $0.stop() } }
        check(downloaded.downloadedURLs == [remote, sidecar, logical] && Set(fake.downloadCalls) == [remote, sidecar, logical]
              && fake.downloadCalls.count == 3,
              "Folder allowed: download only initially nonlocal files, deduplicating overlapping roots")
        check(downloaded.items.count == 4 && downloaded.items.first { $0.primary.url == paired }?.photo.edited == true,
              "Folder allowed: downloaded placeholders decode and downloaded sidecars protect their whole item")
        check(downloaded.downloadedFiles.allSatisfy { file in
            file.size == (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }, "Folder accounting: downloaded file sizes come from local resource values")
        let next = try await FolderScanPipeline.scan(roots: [root], ubiquityPort: fake.port)
        defer { next.accesses.forEach { $0.stop() } }
        check(next.downloadedURLs.isEmpty,
              "Folder accounting: a new scan of already local files reports no prior downloads")

        // Modify one identity snapshot and replace another with identical bytes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: remote.path)
        let original = try Data(contentsOf: logical)
        try original.write(to: logical, options: .atomic)
        let refused = await downloaded.evictDownloadedFiles()
        check(refused.first { $0.url == remote }?.outcome == .changed
              && refused.first { $0.url == logical }?.outcome == .changed
              && refused.first { $0.url == sidecar }?.outcome == .evicted
              && fake.evictionCalls == [sidecar],
              "Folder eviction: refuses changed mtime/replaced inode; evicts exactly unchanged scan downloads")
        let remainingBytes = try Data(contentsOf: logical)
        check([local, remote, paired, sidecar, logical].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
              && remainingBytes == original,
              "Folder eviction: never deletes or moves files, including rejected replacements and local files")

        // Residency may change after enumeration; neither ImageIO nor hashing
        // may silently materialize it in a later review request.
        fake.setCloud(cloud, missing: [remote])
        let remoteItem = downloaded.items.first { $0.primary.url == remote }!
        let image = await downloaded.imageProvider.image(for: remoteItem.id, profile: .documentHighQuality)
        let hash = await FolderOriginalHasher(items: downloaded.items, ubiquityPort: fake.port)
            .sha256(itemIdentifier: remoteItem.id)
        check(image == nil && hash == nil && fake.downloadCalls.count == 3,
              "Folder reads: newly evicted files return no image/hash and never launch a later unaccounted download")

        fake.downloadSucceeds = false
        fake.setCloud(cloud, missing: [remote])
        options.iCloudDownloadPolicy = .allowed
        options.iCloudDownloadTimeout = 0
        let timedOut = try await FolderScanPipeline.scan(roots: [root], options: options, ubiquityPort: fake.port)
        defer { timedOut.accesses.forEach { $0.stop() } }
        check(!timedOut.items.contains { $0.primary.url == remote } && timedOut.downloadedURLs.isEmpty
              && timedOut.issues.contains { $0.url == remote && $0.reason == .notOnDevice },
              "Folder allowed: bounded download timeout skips with notOnDevice and records no completed download")

        fake.setCloud([remote], unknown: [remote], stale: [])
        let unknown = try FolderEnumerator.enumerate(root: root, iCloudDownloadPolicy: .localOnly, ubiquityPort: fake.port)
        check(unknown.issues.contains { $0.url == remote && $0.reason == .notOnDevice },
              "Folder localOnly: unknown ubiquitous residency never authorizes a pixel read")
        fake.setCloud([remote], stale: [remote])
        let callsBefore = fake.downloadCalls.count
        let stale = try FolderEnumerator.enumerate(root: root, iCloudDownloadPolicy: .localOnly, ubiquityPort: fake.port)
        check(stale.items.contains { $0.primary.url == remote } && fake.downloadCalls.count == callsBefore,
              "Folder localOnly: stale downloaded copy is local and does not trigger synchronization")

        fake.downloadSucceeds = true
        fake.setCloud([remote, sidecar], missing: [remote, sidecar])
        let failures = try await FolderScanPipeline.scan(roots: [root], ubiquityPort: fake.port)
        defer { failures.accesses.forEach { $0.stop() } }
        fake.evictionFailure = remote
        fake.setCloud([remote]) // A downloaded sidecar is no longer ubiquitous.
        let report = await failures.evictDownloadedFiles()
        let hasFailure: Bool
        if case .failed = report.first(where: { $0.url == remote })?.outcome { hasFailure = true }
        else { hasFailure = false }
        check(hasFailure && report.first { $0.url == sidecar }?.outcome == .noLongerUbiquitous,
              "Folder eviction: reports individual API failures and refuses files no longer in iCloud")
        check(FileManager.default.fileExists(atPath: remote.path) && FileManager.default.fileExists(atPath: sidecar.path),
              "Folder eviction: failure has no delete or move fallback")
    } catch {
        check(false, "Folder iCloud fixture error: \(error)")
    }
}

/// Exercises the exact enumeration gate and result eviction API independently
/// of the host's LaunchServices type registry. Ubiquity is fake; stat identity,
/// file bytes, modification dates and resource-value sizes are real.
@MainActor
private func checkFolderICloudGates() async {
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapsift-cloud-gates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local.bin")
        let remote = root.appendingPathComponent("remote.bin")
        let changed = root.appendingPathComponent("changed.bin")
        let replaced = root.appendingPathComponent("replaced.bin")
        let fails = root.appendingPathComponent("fails.bin")
        let noCloud = root.appendingPathComponent("no-cloud.bin")
        let placeholder = root.appendingPathComponent(".placeholder.png.icloud")
        let logical = root.appendingPathComponent("placeholder.png")
        let files: [URL] = [local, remote, changed, replaced, fails, noCloud, placeholder]
        let bytes = Data("fixture contents".utf8)
        for url in files { try bytes.write(to: url) }
        let cloud: Set<URL> = [remote, changed, replaced, fails, noCloud, placeholder, logical]
        let fake = FakeFolderUbiquity()
        fake.placeholderTarget = logical
        fake.setCloud(cloud, missing: cloud)
        let off = FolderICloudAccess(policy: .localOnly, port: fake.port, timeout: 0)
        let skip = try off.prepareForScan(remote)
        let placeholderSkip = try off.prepareForScan(logical, placeholder: placeholder)
        check(skip?.url == remote && skip?.reason == .notOnDevice
              && placeholderSkip?.url == logical && placeholderSkip?.reason == .notOnDevice
              && fake.downloadCalls.isEmpty && off.downloadedFiles.isEmpty,
              "Folder gate: localOnly skips nonlocal files/placeholders with notOnDevice and no download request")
        check(off.logicalURL(for: placeholder) == logical && off.logicalURL(for: local) == nil,
              "Folder gate: recognizes the public-resource-confirmed .name.ext.icloud convention")
        fake.setCloud(cloud, unknown: [remote], stale: [changed])
        check(try off.prepareForScan(remote)?.reason == .notOnDevice,
              "Folder gate: unknown ubiquitous residency is unavailable")
        check(try off.prepareForScan(changed) == nil,
              "Folder gate: downloaded/stale local copy is readable without synchronization")

        fake.setCloud(cloud, missing: cloud)
        let on = FolderICloudAccess(policy: .allowed, port: fake.port, timeout: 0)
        for url in [local, remote, changed, replaced, fails, noCloud] {
            check(try on.prepareForScan(url) == nil, "Folder gate: allowed prepares \(url.lastPathComponent)")
        }
        check(try on.prepareForScan(logical, placeholder: placeholder) == nil,
              "Folder gate: allowed downloads the logical file, never decodes placeholder bytes")
        _ = try on.prepareForScan(remote)
        let receipt = FolderScanResult(downloadedFiles: on.downloadedFiles, ubiquityPort: fake.port,
            items: [], groups: [], exactGroupIDs: [], crossFolderDuplicates: [], roots: [], issues: [],
            primaryHashes: [:], uniqueMetadataWithheld: 0, uniqueMetadataIDs: [],
            imageProvider: FolderImageProvider(items: []), accesses: [])
        let expected: Set<URL> = [remote, changed, replaced, fails, noCloud, logical]
        check(receipt.downloadedURLs == expected && Set(fake.downloadCalls) == expected && fake.downloadCalls.count == 6,
              "Folder gate: records only completed downloads, deduplicates URLs and excludes initially local files")
        check(receipt.downloadedFiles.allSatisfy {
            $0.size == (try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }, "Folder gate: receipt reports post-download resource-value sizes")
        let fresh = FolderICloudAccess(policy: .allowed, port: fake.port, timeout: 0)
        _ = try fresh.prepareForScan(remote)
        check(fresh.downloadedFiles.isEmpty, "Folder gate: a new scan starts with no previous download records")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: changed.path)
        try bytes.write(to: replaced, options: .atomic)
        fake.evictionFailure = fails
        fake.setCloud(cloud.subtracting([noCloud]))
        let evictions = await receipt.evictDownloadedFiles()
        var failed = false
        if case .failed = evictions.first(where: { $0.url == fails })?.outcome { failed = true }
        check(evictions.first { $0.url == changed }?.outcome == .changed
              && evictions.first { $0.url == replaced }?.outcome == .changed
              && evictions.first { $0.url == noCloud }?.outcome == .noLongerUbiquitous && failed
              && Set(fake.evictionCalls) == [remote, logical],
              "Folder gate eviction: live identity/mtime/ubiquity gates and per-file API failures are enforced")
        let stillThere = (files + [logical]).allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        let localBytes = try Data(contentsOf: local)
        let replacementBytes = try Data(contentsOf: replaced)
        check(stillThere && localBytes == bytes && replacementBytes == bytes,
              "Folder gate eviction: no delete/move fallback; changed and initially local files remain untouched")

        fake.downloadSucceeds = false
        fake.setCloud(cloud, missing: [remote])
        let timeout = FolderICloudAccess(policy: .allowed, port: fake.port, timeout: 0)
        check(try timeout.prepareForScan(remote)?.reason == .notOnDevice,
              "Folder gate: bounded download timeout reports notOnDevice")
        check(timeout.downloadedFiles.isEmpty, "Folder gate: timed-out downloads are not claimed as completed")
        fake.setCloud(cloud)
        check(timeout.downloadedFiles.map(\.url) == [remote],
              "Folder gate: final receipt includes a timed-out download that completed before the scan finished")
    } catch {
        check(false, "Folder iCloud gate fixture error: \(error)")
    }
}
