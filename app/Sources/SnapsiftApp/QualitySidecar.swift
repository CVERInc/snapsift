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
    /// Where a Photos library lives if the user never moved it. This is a GUESS,
    /// never an identity: a library "copied" (not moved) to an external disk and
    /// then set as the system library leaves a full, stale duplicate right here —
    /// same asset UUIDs, same schema, months out of date. Reading it answers
    /// every question plausibly and every question wrong, and the one that
    /// matters is `edited`. Always go through `locate()`.
    static let fallbackLibraryPath =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photos Library.photoslibrary").path
    #else
    // The Photos.sqlite sidecar is a macOS-only capability (Full Disk Access
    // into the user's library bundle). The iOS sandbox can never read it —
    // the app runs on the existing `qualityAvailable = false` degradation.
    static let fallbackLibraryPath = ""
    #endif

    /// The library path Photos itself records, resolved from its own preference
    /// bookmark (`IPXDefaultLibraryURLBookmark` in com.apple.Photos). nil when it
    /// cannot be read — which the caller must treat as "identity unknown", not
    /// as "the default path is fine".
    ///
    /// WHAT THIS KEY MEANS, precisely, because the protection guarantee rests on
    /// it: it is the library Photos.app LAST OPENED. That is the System Photo
    /// Library on every ordinary Mac, but the two are not the same field, and
    /// they diverge for anyone who ⌥-launched Photos onto a second library once.
    /// PhotoKit publishes no library URL of its own (`PHPhotoLibrary` has no
    /// such public API; the older osxphotos heuristic,
    /// com.apple.photolibraryd's `SystemLibraryPath`, no longer exists on macOS
    /// 26 — checked, it is gone), so there is nothing better to compare against.
    /// The path check is therefore the CHEAP half of the identity proof and the
    /// freshness probe in `evaluateLibraryIdentity` is the half that catches the
    /// divergence: a library Photos merely opened once is missing everything
    /// imported since, and fails it.
    ///
    /// Read-only and side-effect-free on purpose: `.withoutUI` so a stale
    /// bookmark can never put a dialog in front of the user, `.withoutMounting`
    /// so probing an unplugged external library never spins up a mount. (An
    /// instrument that changes what it measures is not an instrument.)
    static func photosLibraryPath() -> String? {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(
                "Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist"),
            home.appendingPathComponent("Library/Preferences/com.apple.Photos.plist"),
        ]
        for url in candidates {
            guard let plist = NSDictionary(contentsOf: url),
                  let bookmark = plist["IPXDefaultLibraryURLBookmark"] as? Data else { continue }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &stale) else { continue }
            return resolved.path
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Which database to read, and what we know about its identity.
    /// `photosLibraryPath == nil` ⇒ unverified: the caller must not trust
    /// `edited` from this file (see `evaluateLibraryIdentity`).
    struct Location {
        let path: String
        let photosLibraryPath: String?
    }

    /// Is there a readable Photos.sqlite under this library bundle right now?
    /// Used to decide whether the declared library is actually AVAILABLE — an
    /// external library that is unplugged is declared but not present.
    static func hasDatabase(at libraryPath: String) -> Bool {
        guard !libraryPath.isEmpty else { return false }
        return FileManager.default.isReadableFile(atPath: "\(libraryPath)/database/Photos.sqlite")
    }

    static func locate() -> Location {
        let declared = photosLibraryPath()
        // Prefer the library Photos names, even when it is somewhere unexpected:
        // the external-disk user was reading a stale ~/Pictures copy AND being
        // told to grant Full Disk Access they had already granted.
        //
        // …but only if it is REALLY THERE. When the declared library is on an
        // unplugged external disk (or was moved away under a stale bookmark),
        // the path we can actually read is the old copy at the default
        // location — and that copy keeps every asset UUID, so every lookup
        // succeeds and every `edited` answer is months old. Returning both
        // paths is what lets `evaluateLibraryIdentity` return `.pathMismatch`
        // for exactly that case instead of the branch being unreachable: the
        // quality/sharpness numbers stay useful for RANKING, and
        // `sidecarTrusted` stays false so nothing in that file is ever
        // evidence about protection.
        if let declared, hasDatabase(at: declared) {
            return Location(path: declared, photosLibraryPath: declared)
        }
        return Location(path: fallbackLibraryPath, photosLibraryPath: declared)
    }

    /// Load the enrichment map. Heavy (one row per asset) — call off the main
    /// actor. `shouldAbort` is polled periodically so a cancelled scan can bail
    /// out of the row loop (the detached task this runs in does not inherit the
    /// scan task's cancellation).
    static func load(libraryPath: String = locate().path,
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
                            libraryPath: String = locate().path) -> [String: Bool]? {
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

    // MARK: - User metadata (exact-duplicate "carries unique metadata" probe)

    /// Whether each asset carries a user-entered caption / title / description.
    ///
    /// Two byte-identical files are interchangeable as pixels but not as library
    /// entries — one of them may be the copy the user wrote a caption on. The
    /// sheet shows two indistinguishable thumbnails, so the user cannot catch
    /// this; the pre-mark must.
    ///
    /// Returns nil when the columns this reads are not in THIS library's schema
    /// (Photos renames tables between releases) or the file is unreadable. nil
    /// means UNDETERMINED, which the Core rule treats as "carries unique
    /// metadata" — the frame is then not pre-marked. Degrading to "no caption"
    /// would be the one unsafe answer, so it is not an option here.
    static func userMetadata(zuuids: [String],
                             libraryPath: String = locate().path) -> [String: Bool]? {
        guard !libraryPath.isEmpty else { return nil }
        guard !zuuids.isEmpty else { return [:] }
        let dbPath = "\(libraryPath)/database/Photos.sqlite"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(dbPath)?mode=ro", &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        // Schema discovery FIRST: never assume a column name we have not seen in
        // this file. A missing one returns nil (undetermined) rather than a
        // query that silently reports "no caption anywhere".
        guard hasColumn(db, table: "ZADDITIONALASSETATTRIBUTES", column: "ZTITLE"),
              hasColumn(db, table: "ZADDITIONALASSETATTRIBUTES", column: "ZASSETDESCRIPTION"),
              hasColumn(db, table: "ZASSETDESCRIPTION", column: "ZLONGDESCRIPTION")
        else { return nil }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var out: [String: Bool] = [:]
        var start = 0
        while start < zuuids.count {
            let chunk = Array(zuuids[start..<min(start + 500, zuuids.count)])
            start += 500
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT z.ZUUID,
                       COALESCE(LENGTH(TRIM(a.ZTITLE)), 0),
                       COALESCE(LENGTH(TRIM(d.ZLONGDESCRIPTION)), 0)
                FROM ZASSET z
                LEFT JOIN ZADDITIONALASSETATTRIBUTES a ON a.ZASSET = z.Z_PK
                LEFT JOIN ZASSETDESCRIPTION d ON d.Z_PK = a.ZASSETDESCRIPTION
                WHERE z.ZUUID IN (\(placeholders))
                """
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
                    let titled = sqlite3_column_int64(stmt, 1) > 0
                    let described = sqlite3_column_int64(stmt, 2) > 0
                    out[String(cString: cstr)] = titled || described
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    return nil
                }
            }
        }
        return out
    }

    /// True when `table.column` exists in this database. `pragma table_info`
    /// returns no rows for a table that isn't there, so one helper covers both.
    private static func hasColumn(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }
}
