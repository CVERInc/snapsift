import SnapsiftPhotoKit

/// Localization for shared membership-only album writing.
enum AlbumWriter {
    // MARK: - Album name constants

    /// All snapsift albums share this prefix so they are easy to identify and
    /// round-trip correctly back into slice 2's album-input source picker.
    static let prefix = "Snapsift · "

    /// Localized album title for the bursts / near-duplicates review bucket.
    /// NOT a delete bucket — candidates for the user to review.
    static func albumBursts(_ t: L10n) -> String  { prefix + t.albumNameBursts() }
    /// Localized album title for frames that appear blurry relative to their
    /// cluster partner. Only members of a real multi-photo cluster, never lone
    /// photos. NOT a delete bucket.
    static func albumBlurry(_ t: L10n) -> String  { prefix + t.albumNameBlurry() }
    /// Localized album title for frames flagged as documents/IDs/receipts.
    /// Organizational only — explicitly NOT a delete bucket.
    static func albumDocs(_ t: L10n) -> String    { prefix + t.albumNameDocs() }
    /// Localized album title for frames that meet the strict exact-duplicate
    /// bar (dHash distance 0 + feature-print ≈0 + same dimensions). This is
    /// the ONLY album whose non-keeper, non-protected members the UI may badge
    /// as "可安心清 / safe to remove".
    static func albumExact(_ t: L10n) -> String   { prefix + t.albumNameExact() }
    /// Localized album title for frames snapsift could NOT classify at all —
    /// edit state unreadable, document eval ran blind, or (for a video) Live
    /// Photo pairing undetermined. NEVER a delete bucket, and unlike the other
    /// four buckets it is not even a REVIEW-for-deletion bucket: per doctrine
    /// (ruling, chodaict, 2026-09-16) these frames are never candidates —
    /// they are collected here strictly so the human can decide in Photos.app.
    static func albumNeedsLook(_ t: L10n) -> String { prefix + t.albumNameNeedsLook() }

    /// Every language's title for a bucket. Album resolution matches ANY of these
    /// so flipping the UI language between sorts resolves the album the user
    /// already has instead of spawning a duplicate parallel set — the localized
    /// title alone can't be the idempotency key. Creation still uses the active
    /// language's title (passed separately as `name`).
    static func allTitles(_ suffix: (L10n) -> String) -> [String] {
        Language.allCases.map { prefix + suffix(L10n($0)) }
    }

    /// Titles an EARLIER snapsift gave this same bucket, before the 2026-09-16
    /// rename (ruling, chodaict). They are NOT dead history: a dogfooded library
    /// already has albums under these names, and every place that resolves the
    /// bucket has to keep recognising them — otherwise the next sort creates a
    /// second, parallel album beside the one the user has been using, and
    /// reconcile stops seeing the frames already filed there.
    ///
    /// Retired names only ever get appended here; nothing is removed.
    static let legacyNeedsLookTitles: [String] = [
        prefix + "Needs a look",   // en-US, until 2026-09-16
        prefix + "請你看看",        // zh-TW, until 2026-09-16
        // ja-JP 「要確認」 was not renamed, so it needs no legacy entry.
    ]

    /// Every title this bucket answers to: the current one in each language,
    /// plus the retired ones. Album RESOLUTION uses this; album CREATION still
    /// uses the active language's current title.
    static var allNeedsLookTitles: [String] {
        allTitles { $0.albumNameNeedsLook() } + legacyNeedsLookTitles
    }

    /// Every title ANY snapsift build has ever created or could create, across
    /// every bucket and every language — used to exclude the tool's OWN
    /// organizational albums from signals that must reflect only the USER's
    /// library state (see `DeleteDecision.userAlbumCount`, used by
    /// `LibraryModel.libraryMetadata(for:)`).
    static var allSnapsiftTitles: Set<String> {
        Set(allTitles { $0.albumNameBursts() }
            + allTitles { $0.albumNameBlurry() }
            + allTitles { $0.albumNameDocs() }
            + allTitles { $0.albumNameExact() }
            + allNeedsLookTitles)
    }


    static func titles(_ t: L10n) -> PhotoLibraryAlbumTitles {
        PhotoLibraryAlbumTitles(
            bursts: .init(name: albumBursts(t), candidateTitles: allTitles { $0.albumNameBursts() }),
            blurry: .init(name: albumBlurry(t), candidateTitles: allTitles { $0.albumNameBlurry() }),
            documents: .init(name: albumDocs(t), candidateTitles: allTitles { $0.albumNameDocs() }),
            exact: .init(name: albumExact(t), candidateTitles: allTitles { $0.albumNameExact() }),
            needsLook: .init(name: albumNeedsLook(t), candidateTitles: allNeedsLookTitles))
    }
}
