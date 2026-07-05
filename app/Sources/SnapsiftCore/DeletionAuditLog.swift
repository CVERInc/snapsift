import Foundation

// MARK: - Audit record types

/// The reason a specific photo was included in a deletion batch.
public enum DeletionReason: String, Codable, Sendable, Equatable {
    case burstNonKeeper        // RESERVED (kept for decode compat) — bursts are never auto-seeded
    case exactDuplicate        // app-seeded: byte-verified exact duplicate
    case blurry                // RESERVED (kept for decode compat) — blur never marks a deletion
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
    /// Never throws — audit-log failure must NEVER abort a deletion — but returns
    /// false so the caller can honestly report a missing record (a mass delete that
    /// wrote no audit line undermines the accountability story otherwise).
    @discardableResult
    public static func append(_ session: DeletionSession, to url: URL = logURL) -> Bool {
        guard !session.records.isEmpty else { return true }
        do {
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = []   // compact single line
            let data = try encoder.encode(session)
            guard var line = String(data: data, encoding: .utf8) else { return false }
            line += "\n"
            let lineData = Data(line.utf8)
            if fm.fileExists(atPath: url.path) {
                // Throwing variants only: the legacy seekToEndOfFile()/write()
                // raise ObjC exceptions on I/O failure that Swift's catch can't
                // see — on a nearly-full disk (this app's primary use case!)
                // that would CRASH right after the destructive commit, before
                // group pruning and the snapshot sync run.
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: url, options: .atomic)
            }
            return true
        } catch {
            // Never fatal — the deletion already committed — but the caller is told
            // so it can surface "deleted, but couldn't write the audit record".
            return false
        }
    }

    // MARK: - Read

    /// Load all sessions from the log, newest-first. Returns empty array if the
    /// file doesn't exist; a malformed line costs that line only.
    /// `url` defaults to the real log — tests point it at a temp file so the
    /// I/O path is exercised without touching the user's actual history.
    public static func loadSessions(from url: URL = logURL) -> [DeletionSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var sessions: [DeletionSession] = []
        // Split on raw newline BYTES — never a whole-file UTF-8 decode, where a
        // single corrupt byte (torn write, disk fault) nils the decode and
        // silently blanks the ENTIRE accountability history. Line-scoped
        // decoding keeps every intact session readable around the damage.
        for lineData in data.split(separator: UInt8(ascii: "\n")) where !lineData.isEmpty {
            if let session = try? decoder.decode(DeletionSession.self, from: Data(lineData)) {
                sessions.append(session)
            }
        }
        return sessions.reversed()   // newest-first
    }

    // MARK: - Export helpers

    /// Localized labels for the plain-text export. SnapsiftCore stays
    /// UI-framework-free, so the app layer injects translated strings (and a
    /// reason mapper) instead of Core importing L10n. Defaults are English, so a
    /// caller with no localization still gets a sensible file.
    public struct ExportLabels: Sendable {
        public let title: String
        public let empty: String
        public let unknown: String
        public let reasonLabel: String
        public let keeperLabel: String
        public let noSurvivor: String
        public let session: @Sendable (_ date: String, _ count: Int) -> String
        public let recoverable: @Sendable (_ until: String) -> String
        public let reasonName: @Sendable (DeletionReason) -> String
        /// Locale used to format the dates embedded in the export.
        public let dateLocale: Locale

        public init(
            title: String = "snapsift Deletion History",
            empty: String = "No deletion history.",
            unknown: String = "unknown",
            reasonLabel: String = "reason:",
            keeperLabel: String = "keeper:",
            noSurvivor: String = "(no survivor)",
            session: @escaping @Sendable (String, Int) -> String = { "Session: \($0)  (\($1) photos removed)" },
            recoverable: @escaping @Sendable (String) -> String = { "In Recently Deleted — recoverable until \($0)" },
            reasonName: @escaping @Sendable (DeletionReason) -> String = { $0.rawValue },
            dateLocale: Locale = .current
        ) {
            self.title = title
            self.empty = empty
            self.unknown = unknown
            self.reasonLabel = reasonLabel
            self.keeperLabel = keeperLabel
            self.noSurvivor = noSurvivor
            self.session = session
            self.recoverable = recoverable
            self.reasonName = reasonName
            self.dateLocale = dateLocale
        }
    }

    /// Return a human-readable plain-text summary of all sessions, suitable for
    /// writing to a .txt export file.
    public static func exportText(sessions: [DeletionSession],
                                  labels: ExportLabels = ExportLabels()) -> String {
        guard !sessions.isEmpty else { return labels.empty }
        var lines: [String] = [labels.title, String(repeating: "=", count: 24), ""]
        let df = ISO8601DateFormatter()
        let displayFmt = DateFormatter()
        displayFmt.locale = labels.dateLocale
        displayFmt.dateStyle = .medium
        displayFmt.timeStyle = .short
        for session in sessions {
            let date = df.date(from: session.timestamp).map { displayFmt.string(from: $0) } ?? session.timestamp
            let recoverUntil: String
            if let d = session.recoverableUntil {
                recoverUntil = displayFmt.string(from: d)
            } else {
                recoverUntil = labels.unknown
            }
            lines.append(labels.session(date, session.records.count))
            lines.append(labels.recoverable(recoverUntil))
            for r in session.records {
                let name = r.filename.isEmpty ? r.assetIdentifier : r.filename
                let kb = r.sizeBytes > 0 ? " [\(r.sizeBytes / 1024) KB]" : ""
                // Empty keeper fields are the no-survivor sentinel (the group's
                // keeper was itself force-rejected) — never print a blank keeper.
                let keeper = (r.keeperFilename.isEmpty && r.keeperIdentifier.isEmpty)
                    ? labels.noSurvivor : r.keeperFilename
                lines.append("  - \(name)\(kb)  \(labels.reasonLabel) \(labels.reasonName(r.reason))  \(labels.keeperLabel) \(keeper)")
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
    /// model, whether the group had `includeProtected` set, and whether the
    /// rejection was seeded by the app's exact-duplicate pass (as opposed to an
    /// explicit user action). The distinction is the point of the audit log:
    /// the app must never book its own suggestions as the user's choices.
    public static func reason(
        for photo: Photo,
        includeProtectedActive: Bool,
        autoSeededExact: Bool = false
    ) -> DeletionReason {
        guard photo.isProtected && includeProtectedActive else {
            return autoSeededExact ? .exactDuplicate : .userRejected
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
