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

    /// Book only vanished, unlogged assets. The caller supplies a live public fetch.
    @discardableResult
    public func reconcile(stillExisting: ([String]) -> Set<String>) -> Int {
        guard let intent = DeletionAuditLog.pendingIntent(at: storage.journalURL) else { return 0 }
        let existing = stillExisting(intent.records.map(\.assetIdentifier))
        let logged = DeletionAuditLog.loggedAssetIdentifiers(from: loadSessions())
        let records = DeletionAuditLog.recoverableRecords(from: intent,
                                                          stillExisting: existing,
                                                          alreadyLogged: logged)
        var recovered = 0
        if !records.isEmpty {
            let session = DeletionSession(timestamp: intent.timestamp, records: records)
            if DeletionAuditLog.append(session, to: storage.historyURL) { recovered = records.count }
        }
        DeletionAuditLog.clearIntent(at: storage.journalURL)
        return recovered
    }
}
