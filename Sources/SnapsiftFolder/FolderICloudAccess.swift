import Foundation
import SnapsiftCore

/// Public resource-value seam for iCloud Drive, including synthetic test files.
public struct FolderUbiquityState: Sendable {
    public let isUbiquitousItem: Bool
    public let downloadingStatus: URLUbiquitousItemDownloadingStatus?
    public let fileSize: Int?

    public init(isUbiquitousItem: Bool, downloadingStatus: URLUbiquitousItemDownloadingStatus?,
                fileSize: Int? = nil) {
        self.isUbiquitousItem = isUbiquitousItem
        self.downloadingStatus = downloadingStatus
        self.fileSize = fileSize
    }

    /// `downloaded` includes a stale local copy; localOnly must not fetch a newer one.
    public var isLocal: Bool {
        !isUbiquitousItem || downloadingStatus == .current || downloadingStatus == .downloaded
    }
}

/// Closures run on utility/decoder queues and must support concurrent calls.
/// Do not mutate a port while a scan or eviction is using it.
public struct FolderUbiquityPort: @unchecked Sendable {
    public var state: (URL) throws -> FolderUbiquityState
    public var startDownload: (URL) throws -> Void
    public var evict: (FolderMember) throws -> Void

    public init(state: @escaping (URL) throws -> FolderUbiquityState,
                startDownload: @escaping (URL) throws -> Void,
                evict: @escaping (FolderMember) throws -> Void) {
        self.state = state; self.startDownload = startDownload; self.evict = evict
    }

    public static let system = FolderUbiquityPort(state: { url in
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey,
        ])
        return FolderUbiquityState(isUbiquitousItem: values.isUbiquitousItem == true,
                                   downloadingStatus: values.ubiquitousItemDownloadingStatus,
                                   fileSize: values.fileSize)
    }, startDownload: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }, evict: { member in
        // Re-check inside coordination so a cooperating writer cannot change or
        // replace the file between the identity gate and eviction.
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: member.url, options: [], error: &coordinationError) { url in
            do {
                guard try FolderMember.read(at: url) == member else { throw FolderEvictionError.changed }
                try FileManager.default.evictUbiquitousItem(at: url)
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
    })
}

private enum FolderEvictionError: Error { case changed }

public struct FolderDownloadedFile: Codable, Sendable {
    public let url: URL
    /// Resource-value size after the file becomes local; nil means unavailable.
    public let size: Int?
    let member: FolderMember
    let receiptID: UUID

    init(url: URL, size: Int?, member: FolderMember, receiptID: UUID = UUID()) {
        self.url = url; self.size = size; self.member = member; self.receiptID = receiptID
    }
}

public struct FolderICloudEvictionResult: Sendable {
    public let url: URL
    public let outcome: Outcome
    public enum Outcome: Equatable, Sendable {
        case evicted
        case changed
        case noLongerUbiquitous
        case failed(String)
    }
}

/// One instance per scan, shared across overlapping roots. Retained providers
/// re-check residency but never start downloads after enumeration has finished.
final class FolderICloudAccess: @unchecked Sendable {
    let policy: ICloudDownloadPolicy
    let port: FolderUbiquityPort
    let timeout: TimeInterval
    private let lock = NSLock()
    private var records: [URL: FolderDownloadedFile] = [:]
    private var pending: Set<URL> = []
    private let downloadStore: FolderDownloadStore?
    private let downloadRoots: [URL: UUID]

    init(policy: ICloudDownloadPolicy, port: FolderUbiquityPort, timeout: TimeInterval,
         downloadStore: FolderDownloadStore? = nil, downloadRoots: [URL: UUID] = [:]) {
        self.policy = policy; self.port = port
        self.timeout = timeout.isFinite ? max(0, timeout) : 30
        self.downloadStore = downloadStore
        self.downloadRoots = downloadRoots
    }

    var downloadedFiles: [FolderDownloadedFile] {
        // A timed-out file may finish while the rest of the scan is working.
        // Include those completions in the final receipt even though their
        // photo item was skipped at enumeration's deadline.
        lock.lock(); let candidates = pending; lock.unlock()
        for url in candidates { _ = try? recordIfLocal(url) }
        lock.lock(); defer { lock.unlock() }
        return records.values.sorted { $0.url.path < $1.url.path }
    }

    private func recordIfLocal(_ url: URL) throws -> Bool {
        guard let state = try? port.state(url), state.isLocal,
              let member = try? FolderMember.read(at: url) else { return false }
        lock.lock(); defer { lock.unlock() }
        if records[url] == nil {
            records[url] = FolderDownloadedFile(url: url, size: state.fileSize, member: member)
        }
        if let downloadStore {
            try downloadStore.record(records[url]!, roots: downloadRoots)
        }
        pending.remove(url)
        return true
    }

    func isLocal(_ url: URL) -> Bool { (try? port.state(url).isLocal) == true }

    /// A placeholder is metadata, never image bytes. Confirm ubiquity as well as
    /// the naming convention so similarly named ordinary hidden files stay hidden.
    func logicalURL(for url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > 8,
              (try? port.state(url).isUbiquitousItem) == true else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
    }

    func prepare(_ url: URL, placeholder: URL? = nil) throws -> Bool {
        let initial = try port.state(placeholder ?? url)
        if placeholder == nil && initial.isLocal { return true }
        if placeholder != nil, isLocal(url), (try? FolderMember.read(at: url)) != nil { return true }
        guard policy == .allowed else { return false }
        do { try port.startDownload(url) } catch { return false }
        lock.lock(); pending.insert(url); lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if Task.isCancelled {
                if downloadStore != nil { _ = try recordIfLocal(url) }
                throw CancellationError()
            }
            if try recordIfLocal(url) { return true }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            // Foundation cannot cancel a started download. The final receipt
            // checks again; completions after that snapshot are not claimed.
            guard remaining > 0 else { return false }
            // Enumeration runs on a detached utility worker, never the UI.
            Thread.sleep(forTimeInterval: min(0.1, remaining))
        } while true
    }

    func prepareForScan(_ url: URL, placeholder: URL? = nil) throws -> FolderEnumerationIssue? {
        try prepare(url, placeholder: placeholder) ? nil : FolderEnumerationIssue(url: url, reason: .notOnDevice)
    }

    static func evict(_ files: [FolderDownloadedFile], port: FolderUbiquityPort,
                      skipNonlocal: Bool = false) -> [FolderICloudEvictionResult] {
        files.map { file in
            let outcome: FolderICloudEvictionResult.Outcome
            do {
                guard try FolderMember.read(at: file.url) == file.member else { throw FolderEvictionError.changed }
                let state = try port.state(file.url)
                if !state.isUbiquitousItem {
                    outcome = .noLongerUbiquitous
                } else if skipNonlocal && state.downloadingStatus == .notDownloaded {
                    outcome = .evicted
                } else {
                    try port.evict(file.member)
                    outcome = .evicted
                }
            } catch FolderEvictionError.changed {
                outcome = .changed
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            return FolderICloudEvictionResult(url: file.url, outcome: outcome)
        }
    }
}
