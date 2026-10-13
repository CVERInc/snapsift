import Foundation

/// Thread-safe accounting for one scan or faces pass. PhotoKit progress is the
/// only download signal; requesting a network-allowed image alone counts nothing.
public final class PhotoKitDownloadAccounting: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let downloadingAssetCount: Int
        public let downloadedAssetIDs: Set<String>
        let revision: UInt64
    }

    private let lock = NSLock()
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var active: [UUID: String] = [:]
    private var downloaded: Set<String> = []
    private let onChange: @Sendable (Snapshot) -> Void

    /// Notifications originate on PhotoKit callback threads. The session marshals
    /// them onto the main actor; standalone clients must do the same for UI work.
    public init(onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        self.onChange = onChange
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return currentSnapshot()
    }

    /// Invalidates callbacks from requests belonging to the previous operation.
    public func reset() {
        lock.lock()
        generation = UUID()
        active = [:]
        downloaded = []
        publish()
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(downloadingAssetCount: Set(active.values).count,
                 downloadedAssetIDs: downloaded, revision: revision)
    }

    private func publish() {
        revision += 1
        let snapshot = currentSnapshot()
        lock.unlock()
        onChange(snapshot)
    }

    private func publishIfChanged(since previous: Snapshot) {
        let current = currentSnapshot()
        guard current.downloadingAssetCount != previous.downloadingAssetCount
            || current.downloadedAssetIDs != previous.downloadedAssetIDs else {
            lock.unlock()
            return
        }
        publish()
    }

    func request(for id: String) -> Request {
        lock.lock(); defer { lock.unlock() }
        return Request(owner: self, assetID: id, generation: generation)
    }

    /// Remains alive for late PhotoKit callbacks after the first image/deadline.
    /// A degraded first image still wins delivery, just as before this policy.
    final class Request: @unchecked Sendable {
        let owner: PhotoKitDownloadAccounting
        let assetID: String
        let generation: UUID
        let token = UUID()
        // Protected by the owner's lock, including callback ordering.
        var reportedDownload = false
        var finished = false

        init(owner: PhotoKitDownloadAccounting, assetID: String, generation: UUID) {
            self.owner = owner; self.assetID = assetID; self.generation = generation
        }

        func progress(_ fraction: Double, failed: Bool) {
            owner.lock.lock()
            guard generation == owner.generation, !finished else { owner.lock.unlock(); return }
            let previous = owner.currentSnapshot()
            reportedDownload = true
            if failed {
                finished = true
                owner.active[token] = nil
            } else if fraction >= 1 {
                finished = true
                owner.active[token] = nil
                owner.downloaded.insert(assetID)
            } else {
                owner.active[token] = assetID
            }
            owner.publishIfChanged(since: previous)
        }

        func complete(hasImage: Bool, degraded: Bool, failed: Bool) {
            owner.lock.lock()
            guard generation == owner.generation, !finished, !degraded || failed else { owner.lock.unlock(); return }
            finished = true
            guard reportedDownload else { owner.lock.unlock(); return }
            let previous = owner.currentSnapshot()
            owner.active[token] = nil
            if hasImage && !failed { owner.downloaded.insert(assetID) }
            owner.publishIfChanged(since: previous)
        }
    }
}
