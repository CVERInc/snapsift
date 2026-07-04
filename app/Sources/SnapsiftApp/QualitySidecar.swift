import Foundation
import SQLite3
import SnapsiftCore

/// PhotoKit doesn't expose Apple's per-photo aesthetic scores or the original
/// file size — but they live in the library's Photos.sqlite. This sidecar reads
/// that database read-only/immutable and returns enrichment keyed by ZUUID, so
/// the in-app keeper can rank by real quality + size, exactly like the Python
/// reference. If the file is unreadable (TCC / Full Disk Access not granted, or
/// a non-standard library location) it degrades to empty and the app keeps
/// working on time + dimensions alone.
///
/// Bridge: `PHAsset.localIdentifier` is "<ZUUID>/L0/NNN", so the 36-char prefix
/// before the first "/" is the ZUUID this map is keyed on.
enum QualitySidecar {
    struct Enrichment: Sendable { let quality: Double; let size: Int; let edited: Bool }

    /// ZUUID for a PhotoKit local identifier ("UUID/L0/001" → "UUID").
    static func zuuid(fromLocalIdentifier id: String) -> String {
        if let slash = id.firstIndex(of: "/") { return String(id[..<slash]) }
        return id
    }

    #if os(macOS)
    static let defaultLibraryPath =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary").path
    #else
    // The Photos.sqlite sidecar is a macOS-only capability (Full Disk Access
    // into the user's library bundle). The iOS sandbox can never read it —
    // the app runs on the existing `qualityAvailable = false` degradation.
    static let defaultLibraryPath = ""
    #endif

    /// Load the enrichment map. Heavy (one row per asset) — call off the main
    /// actor. `shouldAbort` is polled periodically so a cancelled scan can bail
    /// out of the row loop (the detached task this runs in does not inherit the
    /// scan task's cancellation).
    static func load(libraryPath: String = defaultLibraryPath,
                     shouldAbort: @Sendable () -> Bool = { false }) -> [String: Enrichment] {
        guard !libraryPath.isEmpty else { return [:] }
        let dbPath = "\(libraryPath)/database/Photos.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return [:]
        }
        defer { sqlite3_close(db) }

        // Column order mirrors scan.py's quality query.
        let sql = """
            SELECT z.ZUUID,
                   COALESCE(a.ZORIGINALFILESIZE, 0),
                   z.ZHIGHLIGHTVISIBILITYSCORE,
                   c.ZSHARPLYFOCUSEDSUBJECTSCORE,
                   c.ZWELLCHOSENSUBJECTSCORE,
                   c.ZWELLFRAMEDSUBJECTSCORE,
                   c.ZWELLTIMEDSHOTSCORE,
                   c.ZINTERESTINGSUBJECTSCORE,
                   c.ZPLEASANTCOMPOSITIONSCORE,
                   c.ZPLEASANTLIGHTINGSCORE,
                   c.ZFAILURESCORE,
                   c.ZNOISESCORE,
                   z.ZADJUSTMENTSSTATE
            FROM ZASSET z
            LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK
            LEFT JOIN ZCOMPUTEDASSETATTRIBUTES  c ON c.ZASSET = z.Z_PK
            WHERE z.ZTRASHEDSTATE = 0
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        func optDouble(_ col: Int32) -> Double? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
        }

        var out: [String: Enrichment] = [:]
        var rows = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows += 1
            if rows % 5000 == 0, shouldAbort() { return [:] }
            guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
            let uuid = String(cString: cstr)
            let size = Int(sqlite3_column_int64(stmt, 1))
            let quality = qualityScore(
                positive: [optDouble(2), optDouble(3), optDouble(4), optDouble(5),
                           optDouble(6), optDouble(7), optDouble(8), optDouble(9)],
                negative: [optDouble(10), optDouble(11)]
            )
            // ZADJUSTMENTSSTATE: 0 = pristine, non-zero (2/3 observed) = the
            // asset carries committed adjustments. Semantically identical to
            // PHAsset.adjustmentFormatIdentifier != nil — cross-verified on a
            // live 121K library: every state≠0 asset (5,419) has a
            // ZUNMANAGEDADJUSTMENT row, every state-0 asset has none. (The
            // ZHASADJUSTMENTS column older schemas had is gone on macOS 26.)
            let edited = sqlite3_column_int64(stmt, 12) != 0
            out[uuid] = Enrichment(quality: quality, size: size, edited: edited)
        }
        return out
    }

    /// Live `edited` flags for specific assets — the recency-sensitive re-check
    /// used by the commit-time protection sweep and the stale-snapshot restore,
    /// both of which exist precisely to catch edits made AFTER the scan.
    ///
    /// Opens plain read-only WITHOUT `immutable=1`: a minutes-old edit sits in
    /// the WAL, and an immutable open (which never reads the WAL) would miss
    /// exactly the rows this query is for. The bulk `load` keeps immutable —
    /// its checkpoint lag is caught by this re-check before anything commits.
    ///
    /// Returns nil when the database is unreadable (no Full Disk Access, or a
    /// query failed mid-way) so the caller can fall back to PhotoKit; a
    /// successful read maps ZUUID → edited for every requested row that exists.
    static func editedFlags(zuuids: [String],
                            libraryPath: String = defaultLibraryPath) -> [String: Bool]? {
        guard !libraryPath.isEmpty else { return nil }
        guard !zuuids.isEmpty else { return [:] }
        let dbPath = "\(libraryPath)/database/Photos.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        // Photos.app writes to this database concurrently; wait out short
        // writer locks instead of failing the whole protection re-check.
        sqlite3_busy_timeout(db, 2000)

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var out: [String: Bool] = [:]
        var start = 0
        while start < zuuids.count {
            let chunk = Array(zuuids[start..<min(start + 500, zuuids.count)])
            start += 500
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT ZUUID, ZADJUSTMENTSSTATE FROM ZASSET WHERE ZUUID IN (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, transient)
            }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                    out[String(cString: cstr)] = sqlite3_column_int64(stmt, 1) != 0
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    return nil   // busy past timeout / IO error → PhotoKit fallback
                }
            }
        }
        return out
    }
}
