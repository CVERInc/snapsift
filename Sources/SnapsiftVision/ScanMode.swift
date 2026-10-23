import SnapsiftCore

/// Source-independent comparisons. Sources own enumeration, scan-cache lifetime,
/// cancellation between stages, enrichment, and exact-duplicate verification.
public enum ScanMode: String, Sendable, CaseIterable {
    case burst, lookAlikes, similarSets

    public var dHashDistance: Int {
        switch self {
        case .burst, .similarSets: return 14
        case .lookAlikes: return 8
        }
    }

    /// Burst uses this for its confident gate; cross-time modes use it to group.
    public var featureDistance: Float {
        switch self {
        case .burst: return 0.10
        case .lookAlikes: return 0.15
        case .similarSets: return 0.45
        }
    }

    public static let maxCluster = 80

    /// Identifier-only grouping for look-alikes and similar sets. Burst needs
    /// capture facts and uses the staged `Burst` comparison instead.
    public func scan(itemIdentifiers: [String], provider: any ImageProvider,
                     progress: @escaping (LookAlikeScanner.Progress, Double?) -> Void) async -> [[String]] {
        precondition(self != .burst, "Burst requires capture facts; use ScanMode.Burst")
        return await LookAlikeScanner.scan(
            itemIdentifiers: itemIdentifiers, provider: provider,
            dHashDistance: dHashDistance, featureDistance: featureDistance,
            maxCluster: Self.maxCluster, progress: progress)
    }

    /// Separate stages preserve source progress and cancellation boundaries.
    public enum Burst {
        public static let gapSec = 3.0
        public static let sizeTol = 0.10
        public static let maxSpan = 30.0
        public static let confidentSpread = 6

        /// Capture facts must be sorted by takenAt, as required by Core cluster.
        public static func candidates(_ photos: [Photo]) -> [[Photo]] {
            cluster(photos, gapSec: gapSec, sizeTol: sizeTol, maxSpan: maxSpan)
        }

        public static func verifyContent(
            _ candidates: [[Photo]], provider: any ImageProvider,
            progress: @escaping (LookAlikeScanner.Progress, Double?) -> Void
        ) async -> [LookAlikeScanner.VerifiedCluster] {
            await LookAlikeScanner.verifyByContent(
                candidates, provider: provider, maxDistance: ScanMode.burst.dHashDistance,
                progress: progress)
        }

        /// Indices align with the supplied verified groups. Missing feature
        /// prints remain uncertain; only dHash-confident groups need inference.
        public static func confidentIndices(
            _ verified: [LookAlikeScanner.VerifiedCluster], provider: any ImageProvider,
            progress: @escaping (LookAlikeScanner.Progress, Double?) -> Void
        ) async -> Set<Int> {
            let indices = verified.indices.filter { verified[$0].spread <= confidentSpread }
            let spreads = await LookAlikeScanner.featureSpreads(
                indices.map { verified[$0].photos.map(\.uuid) }, provider: provider
            ) { done, total, loaded in
                progress(.confirming(done, total, loaded: loaded),
                         total > 0 ? Double(done) / Double(total) : nil)
            }
            var confident = Set<Int>()
            for (offset, index) in indices.enumerated() {
                if let spread = spreads[offset], spread <= ScanMode.burst.featureDistance {
                    confident.insert(index)
                }
            }
            return confident
        }
    }
}
