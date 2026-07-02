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
    struct Enrichment: Sendable { let quality: Double; let size: Int }

    /// ZUUID for a PhotoKit local identifier ("UUID/L0/001" → "UUID").
    static func zuuid(fromLocalIdentifier id: String) -> String {
        if let slash = id.firstIndex(of: "/") { return String(id[..<slash]) }
        return id
    }

    static let defaultLibraryPath =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary").path

    /// Load the enrichment map. Heavy (one row per asset) — call off the main
    /// actor. `shouldAbort` is polled periodically so a cancelled scan can bail
    /// out of the row loop (the detached task this runs in does not inherit the
    /// scan task's cancellation).
    static func load(libraryPath: String = defaultLibraryPath,
                     shouldAbort: @Sendable () -> Bool = { false }) -> [String: Enrichment] {
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
                   c.ZNOISESCORE
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
            out[uuid] = Enrichment(quality: quality, size: size)
        }
        return out
    }
}
