import Foundation
import SnapsiftCore

/// App-owned locations; default filenames preserve the existing macOS data format.
public struct PhotoLibraryStorage: Sendable {
    public let snapshotURL: URL
    public let journalURL: URL
    public let historyURL: URL

    public init(directory: URL) {
        self.init(snapshotURL: directory.appendingPathComponent("last-scan.json"),
                  journalURL: directory.appendingPathComponent("pending-delete.json"),
                  historyURL: directory.appendingPathComponent("deletions.jsonl"))
    }

    public init(snapshotURL: URL, journalURL: URL, historyURL: URL) {
        self.snapshotURL = snapshotURL; self.journalURL = journalURL; self.historyURL = historyURL
    }
}

/// Deletion history and interrupted intent recovery at injected app-owned locations.
public struct PhotoLibraryHistoryStore: Sendable {
    public let storage: PhotoLibraryStorage
    public init(storage: PhotoLibraryStorage) { self.storage = storage }

    public func loadSessions() -> [DeletionSession] {
        DeletionAuditLog.loadSessions(from: storage.historyURL)
    }

    public func exportText(labels: DeletionAuditLog.ExportLabels = .init()) -> String {
        DeletionAuditLog.exportText(sessions: loadSessions(), labels: labels)
    }

    /// Book only vanished, unlogged assets, and only when the library can be
    /// read in full (`access`): "cannot see" is not "gone". Without full
    /// read-write access the journal is left exactly where it is and
    /// `stillExisting` is never called. Returns nil when it deferred, else
    /// the number of records booked.
    ///
    /// When the history write fails the journal is kept too: it is still the
    /// only record of those deletions, and the next reconcile tries again.
    @discardableResult
    public func reconcile(access: DeletionAuditLog.PhotoAccess,
                          stillExisting: ([String]) -> Set<String>) -> Int? {
        guard let intent = DeletionAuditLog.pendingIntent(at: storage.journalURL) else { return 0 }
        let logged = DeletionAuditLog.loggedAssetIdentifiers(from: loadSessions())
        switch DeletionAuditLog.journalReconcile(
            intent: intent, access: access, alreadyLogged: logged,
            stillExisting: { stillExisting(intent.records.map(\.assetIdentifier)) }) {
        case .deferUntilReadable:
            return nil
        case .book(let records):
            if !records.isEmpty {
                let session = DeletionSession(timestamp: intent.timestamp, records: records)
                guard DeletionAuditLog.append(session, to: storage.historyURL) else { return 0 }
            }
            DeletionAuditLog.clearIntent(at: storage.journalURL)
            return records.count
        }
    }
}
