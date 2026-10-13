import Foundation
import Photos
import SnapsiftCore
import SnapsiftVision

/// Optional platform enrichment; absence uses public PhotoKit and unknown protection facts.
@MainActor
public protocol PhotoLibraryEnrichmentPort: AnyObject {
    var qualityAvailable: Bool { get }
    var libraryIdentity: LibraryIdentity { get }
    func loadEnrichment(assets: [PHAsset], shouldAbort: @escaping @Sendable () -> Bool) async
    func verifyLibraryIdentity(sample: [PHAsset]) async
    func discardCancelledLoad()
    func enrichment(for id: String) -> PhotoLibraryEnrichment?
    func assetMetadata(for asset: PHAsset) -> PhotoLibraryAssetMetadata
    /// nil requests the shared per-asset fallback; absent entries stay unknown.
    func editedFlags(for targets: [(uuid: String, asset: PHAsset)]) async -> [String: Bool]?
    func descriptions(for ids: [String]) async -> [String: Bool]?
    nonisolated func setName(tags: [String], language: String) async -> String?
}

/// Ranking values plus edited state from an optionally verified platform source.
public struct PhotoLibraryEnrichment: Sendable {
    public let quality: Double
    public let size: Int
    public let edited: Bool
    public init(quality: Double, size: Int, edited: Bool) {
        self.quality = quality; self.size = size; self.edited = edited
    }
}

/// Public resource metadata, or the macOS app's existing metadata adapter.
public struct PhotoLibraryAssetMetadata: Sendable {
    public let filename: String
    public let uti: String
    public init(filename: String, uti: String) { self.filename = filename; self.uti = uti }
}

/// Structured progress; app shells localize counts without changing orchestration.
public enum PhotoLibraryProgress: Equatable {
    case idle, fetching, readingQuality, writingAlbums
    case clustering(Int)
    case hashing(Int, Int)
    case confirming(Int, Int, loaded: Int)
    case skippedClusters(Int)
    case verifying(Int, Int)
    case faces(Int, Int)
    case naming(Int, Int)

    init(_ progress: LookAlikeScanner.Progress) {
        switch progress {
        case .hashing(let done, let total): self = .hashing(done, total)
        case .confirming(let done, let total, let loaded): self = .confirming(done, total, loaded: loaded)
        case .skippedClusters(let count): self = .skippedClusters(count)
        case .verifying(let done, let total): self = .verifying(done, total)
        }
    }
}

/// Session outcomes that require presentation by the app shell.
public enum PhotoLibraryNotice: Equatable {
    case cancelled, albumGone, restoredStale
    case scanFinished(count: Int, pairedVideosSkipped: Int)
    case restored(Int)
}
