import Foundation

// MARK: - Audit record types

/// The reason a specific photo was included in a deletion batch.
public enum DeletionReason: String, Codable, Sendable, Equatable {
    case burstNonKeeper        // non-keeper in a near-identical burst
    case exactDuplicate        // exact duplicate (dHash 0 + feature ≈0)
    case blurry                // blurrier than the kept frame
    case forceIncludedProtectedFavorite    // user explicitly force-rejected a favorite
    case forceIncludedProtectedEdited      // user explicitly force-rejected an edited photo
    case forceIncludedProtectedDocument   // user explicitly force-rejected a document
    case forceIncludedProtectedMultiple   // user force-rejected a frame with multiple protections
    case userRejected          // user manually rejected (per-frame or reject-all)
}

/// One deleted photo captured in the audit log.
public struct DeletionRecord: Codable, Sendable {
    /// ISO-8601 timestamp of the deletion batch.
    public let timestamp: String
    /// PHAsset localIdentifier of the deleted photo.
    public let assetIdentifier: String
    /// Original filename (may be empty if Photos didn't expose it).
    public let filename: String
    /// File size in bytes (0 if the quality sidecar wasn't readable).
    public let sizeBytes: Int
    /// localIdentifier of the keeper that survived in the same group.
    public let keeperIdentifier: String
    /// Filename of the keeper.
    public let keeperFilename: String
    /// Why this photo was selected for removal.
    public let reason: DeletionReason

    public init(timestamp: String, assetIdentifier: String, filename: String,
                sizeBytes: Int, keeperIdentifier: String, keeperFilename: String,
                reason: DeletionReason) {
        self.timestamp = timestamp
        self.assetIdentifier = assetIdentifier
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.keeperIdentifier = keeperIdentifier
        self.keeperFilename = keeperFilename
        self.reason = reason
    }
}

/// One deletion session — a single "commit" — containing all photos removed
/// in that pass, plus the wall-clock time so the UI can show recovery windows.
public struct DeletionSession: Codable, Sendable {
    /// ISO-8601 timestamp (same as the records' `timestamp` field).
    public let timestamp: String
    /// Photos deleted in this session, in the order they were removed.
    public let records: [DeletionRecord]

    public init(timestamp: String, records: [DeletionRecord]) {
        self.timestamp = timestamp
        self.records = records
    }

    /// Approximate recovery deadline: 30 days from the session timestamp.
    public var recoverableUntil: Date? {
        ISO8601DateFormatter().date(from: timestamp).map { $0.addingTimeInterval(30 * 24 * 3600) }
    }
}

// MARK: - Audit log

/// Append-only audit log stored as JSON Lines in
/// `~/Library/Application Support/snapsift/deletions.jsonl`.
///
/// Each line is a complete `DeletionSession` encoded as JSON — one session
/// per "commit" (deleteReviewed call). Reading the log returns all sessions
/// newest-first.
///
/// This is entirely on-device — no network, no iCloud sync. The file is
/// small (text, ~200–500 bytes per deleted photo) and grows only when the
/// user actually commits deletions.
public struct DeletionAuditLog: Sendable {

    // MARK: - File location

    /// `~/Library/Application Support/snapsift/`
    public static var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        return appSupport.appendingPathComponent("snapsift", isDirectory: true)
    }

    /// `…/snapsift/deletions.jsonl`
    public static var logURL: URL {
        directory.appendingPathComponent("deletions.jsonl")
    }

    // MARK: - Write

    /// Append one session to the log. Creates the directory and file if needed.
    /// Errors are swallowed — audit-log failure must NEVER abort a deletion.
    public static func append(_ session: DeletionSession) {
        guard !session.records.isEmpty else { return }
        do {
            let fm = FileManager.default
            let dir = directory
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = []   // compact single line
            let data = try encoder.encode(session)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            let lineData = Data(line.utf8)
            let url = logURL
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            } else {
                try lineData.write(to: url, options: .atomic)
            }
        } catch {
            // Intentionally silent — audit log is best-effort.
        }
    }

    // MARK: - Read

    /// Load all sessions from the log, newest-first. Returns empty array if the
    /// file doesn't exist or can't be parsed.
    public static func loadSessions() -> [DeletionSession] {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var sessions: [DeletionSession] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = String(line).data(using: .utf8),
               let session = try? decoder.decode(DeletionSession.self, from: lineData) {
                sessions.append(session)
            }
        }
        return sessions.reversed()   // newest-first
    }

    // MARK: - Export helpers

    /// Return a human-readable plain-text summary of all sessions, suitable for
    /// writing to a .txt export file.
    public static func exportText(sessions: [DeletionSession]) -> String {
        guard !sessions.isEmpty else { return "No deletion history." }
        var lines: [String] = ["snapsift Deletion History", "========================", ""]
        let df = ISO8601DateFormatter()
        let displayFmt = DateFormatter()
        displayFmt.dateStyle = .medium
        displayFmt.timeStyle = .short
        for session in sessions {
            let date = df.date(from: session.timestamp).map { displayFmt.string(from: $0) } ?? session.timestamp
            let recoverUntil: String
            if let d = session.recoverableUntil {
                recoverUntil = displayFmt.string(from: d)
            } else {
                recoverUntil = "unknown"
            }
            lines.append("Session: \(date)  (\(session.records.count) photos removed)")
            lines.append("In Recently Deleted — recoverable until \(recoverUntil)")
            for r in session.records {
                let name = r.filename.isEmpty ? r.assetIdentifier : r.filename
                let kb = r.sizeBytes > 0 ? " [\(r.sizeBytes / 1024) KB]" : ""
                lines.append("  - \(name)\(kb)  reason: \(r.reason.rawValue)  keeper: \(r.keeperFilename)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Build helpers

    /// ISO-8601 timestamp string for "now".
    public static func nowTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Derive the `DeletionReason` for a photo being deleted, given its Photo
    /// model and whether the group had `includeProtected` set.
    public static func reason(for photo: Photo, includeProtectedActive: Bool) -> DeletionReason {
        guard photo.isProtected && includeProtectedActive else {
            return .userRejected
        }
        // Multiple protections — use most specific
        let flags = [photo.favorite, photo.edited, photo.isDocument]
        let count = flags.filter { $0 }.count
        if count > 1 { return .forceIncludedProtectedMultiple }
        if photo.favorite   { return .forceIncludedProtectedFavorite }
        if photo.edited     { return .forceIncludedProtectedEdited }
        if photo.isDocument { return .forceIncludedProtectedDocument }
        return .userRejected
    }
}
