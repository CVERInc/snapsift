import Foundation
import Photos
import SnapsiftCore

/// Cross-launch persistence of a scan's results INCLUDING the user's review
/// decisions — the app must reopen onto the last working state instead of
/// forcing a multi-minute rescan of the whole library.
///
/// Stored as one JSON file next to the deletion audit log
/// (`Application Support/snapsift/last-scan.json` — sandbox-legal on iOS too).
/// The snapshot is a value-type mirror of the review state; PHAssets are
/// re-fetched on load and anything that no longer resolves is dropped
/// (a group that falls under 2 frames dissolves). `includeProtected` is
/// deliberately NOT persisted: the protected-override is an informed-consent
/// flag that must never outlive the session that confirmed it.
struct ScanSnapshot: Codable {
    /// Bump when the schema changes; loaders reject unknown versions.
    static let currentSchema = 1

    init(schema: Int = currentSchema, kind: String, sourceID: String?, timestamp: Date,
                changeToken: Data?, groups: [Group], categories: [Category]) {
        self.schema = schema; self.kind = kind; self.sourceID = sourceID; self.timestamp = timestamp
        self.changeToken = changeToken; self.groups = groups; self.categories = categories
    }

    struct Group: Codable {
        init(photos: [Photo], keeperID: String, rejected: [String], autoSeeded: [String],
                    confidentDupe: Bool, exact: Bool) {
            self.photos = photos; self.keeperID = keeperID; self.rejected = rejected
            self.autoSeeded = autoSeeded; self.confidentDupe = confidentDupe; self.exact = exact
        }
        let photos: [Photo]
        let keeperID: String
        let rejected: [String]
        let autoSeeded: [String]
        let confidentDupe: Bool
        /// True when this group passed the exact-duplicate verification.
        let exact: Bool
    }

    struct Category: Codable {
        init(label: String, photos: [Photo]) { self.label = label; self.photos = photos }
        let label: String
        let photos: [Photo]
    }

    let schema: Int
    /// "burst" / "lookAlikes" / "similarSets" — informational.
    let kind: String
    /// Album localIdentifier the scan was scoped to (nil = whole library).
    let sourceID: String?
    let timestamp: Date
    /// Archived PHPersistentChangeToken at save time; lets the loader tell the
    /// user "the library changed since this scan" without blocking the restore.
    let changeToken: Data?
    let groups: [Group]
    let categories: [Category]
}

final class ScanSnapshotStore: @unchecked Sendable {
    let url: URL
    init(url: URL) {
        // Normalize dot components without depending on whether the file exists.
        self.url = url.absoluteURL.standardized
        self.saveQueue = Self.queue(for: self.url)
    }

    /// Serializes writes so enqueue order equals on-disk order: two same-priority
    /// detached saves would otherwise race and an older snapshot could overwrite a
    /// newer one, resurrecting just-deleted frames on relaunch. Callers enqueue
    /// from the main actor, so FIFO here preserves capture order.
    private let saveQueue: DispatchQueue
    private static let queuesLock = NSLock()
    private static var queues: [URL: DispatchQueue] = [:]

    /// Windows share one file; separate apps' snapshot files stay independent.
    private static func queue(for url: URL) -> DispatchQueue {
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let queue = queues[url] { return queue }
        let queue = DispatchQueue(label: "net.cver.snapsift.snapshot-save", qos: .utility)
        queues[url] = queue
        return queue
    }

    /// Write failures never break a scan, but the snapshot is the SOLE store of
    /// the user's review decisions (not a rebuildable cache), so a failure must be
    /// surfaced by the caller — returns false so a disk-full loss doesn't go silent.
    @discardableResult
    private func save(_ snapshot: ScanSnapshot) -> Bool {
        do {
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Enqueue an asynchronous, serialized write and report the outcome on the
    /// caller's actor. The encode+write run on `saveQueue`, so writes land in the
    /// order they were enqueued regardless of scheduler pressure.
    func saveAsync(_ snapshot: ScanSnapshot, completion: @escaping @Sendable (Bool) -> Void) {
        saveQueue.async {
            let ok = self.save(snapshot)
            completion(ok)
        }
    }

    /// Synchronous, ordering-preserving write for app termination: runs on the
    /// same serial queue so it lands AFTER any already-enqueued async writes, and
    /// blocks the caller until the bytes are on disk (the process may exit next).
    @discardableResult
    func saveSync(_ snapshot: ScanSnapshot) -> Bool {
        saveQueue.sync { save(snapshot) }
    }

    /// Distinguishes "nothing to restore" from "there WAS a session but its file
    /// can't be read" — the snapshot is the sole store of the user's review
    /// decisions, so the second case must surface, never silently pass as the
    /// first (an empty launch after hours of review reads as data loss, because
    /// it is).
    enum LoadOutcome {
        case none                  // no snapshot on disk — a genuinely fresh start
        case unreadable            // file exists but corrupt / stale schema
        case ok(ScanSnapshot)
    }

    func loadOutcome() -> LoadOutcome {
        guard let data = try? Data(contentsOf: url) else { return .none }
        guard let snap = try? JSONDecoder().decode(ScanSnapshot.self, from: data),
              snap.schema == ScanSnapshot.currentSchema else {
            // Preserve the bytes for post-mortem instead of letting the next
            // save clobber them; the notice tells the user what happened.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return .unreadable
        }
        return .ok(snap)
    }

    func load() -> ScanSnapshot? {
        if case .ok(let snap) = loadOutcome() { return snap }
        return nil
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

}

/// The library staleness anchor uses only PhotoKit persistent changes.
enum PhotoLibraryChangeToken {
    /// Archived current library change token (nil when unavailable).
    static func currentData() -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    /// True when `saved` matches the CURRENT library state (i.e. nothing
    /// changed since the snapshot). False on any mismatch or decode failure.
    static func isCurrent(_ saved: Data?) -> Bool {
        guard let saved,
              let savedToken = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: PHPersistentChangeToken.self, from: saved)
        else { return false }
        return savedToken == PHPhotoLibrary.shared().currentChangeToken
    }
}
