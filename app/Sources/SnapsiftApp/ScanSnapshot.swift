import Foundation
import Photos
import SnapsiftCore

// `ScanSnapshot` itself (the on-disk shape) lives in SnapsiftCore/AlbumLedger.swift
// so the test suite decodes the real type. This file is the PhotoKit-touching store.

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

    static func loadOutcome() -> LoadOutcome {
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

    static func load() -> ScanSnapshot? {
        if case .ok(let snap) = loadOutcome() { return snap }
        return nil
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
