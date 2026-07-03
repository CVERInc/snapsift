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

    struct Group: Codable {
        let photos: [Photo]
        let keeperID: String
        let rejected: [String]
        let autoSeeded: [String]
        let confidentDupe: Bool
        /// True when this group passed the exact-duplicate verification.
        let exact: Bool
    }

    struct Category: Codable {
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

enum ScanSnapshotStore {
    static var url: URL {
        DeletionAuditLog.directory.appendingPathComponent("last-scan.json")
    }

    /// Serializes writes so enqueue order equals on-disk order: two same-priority
    /// detached saves would otherwise race and an older snapshot could overwrite a
    /// newer one, resurrecting just-deleted frames on relaunch. Callers enqueue
    /// from the main actor, so FIFO here preserves capture order.
    private static let saveQueue = DispatchQueue(label: "net.cver.snapsift.snapshot-save", qos: .utility)

    /// Write failures never break a scan, but the snapshot is the SOLE store of
    /// the user's review decisions (not a rebuildable cache), so a failure must be
    /// surfaced by the caller — returns false so a disk-full loss doesn't go silent.
    @discardableResult
    static func save(_ snapshot: ScanSnapshot) -> Bool {
        do {
            let dir = DeletionAuditLog.directory
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
    static func saveAsync(_ snapshot: ScanSnapshot, completion: @escaping @Sendable (Bool) -> Void) {
        saveQueue.async {
            let ok = save(snapshot)
            completion(ok)
        }
    }

    /// Synchronous, ordering-preserving write for app termination: runs on the
    /// same serial queue so it lands AFTER any already-enqueued async writes, and
    /// blocks the caller until the bytes are on disk (the process may exit next).
    @discardableResult
    static func saveSync(_ snapshot: ScanSnapshot) -> Bool {
        saveQueue.sync { save(snapshot) }
    }

    static func load() -> ScanSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(ScanSnapshot.self, from: data),
              snap.schema == ScanSnapshot.currentSchema else { return nil }
        return snap
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Archived current library change token (nil when unavailable).
    static func currentChangeTokenData() -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    /// True when `saved` matches the CURRENT library state (i.e. nothing
    /// changed since the snapshot). False on any mismatch or decode failure.
    static func changeTokenIsCurrent(_ saved: Data?) -> Bool {
        guard let saved,
              let savedToken = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: PHPersistentChangeToken.self, from: saved)
        else { return false }
        return savedToken == PHPhotoLibrary.shared().currentChangeToken
    }
}
