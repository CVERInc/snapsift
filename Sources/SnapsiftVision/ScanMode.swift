import SnapsiftCore

/// Source-independent comparisons. Sources own enumeration, scan-cache lifetime,
/// cancellation between stages, enrichment, and exact-duplicate verification.
public enum ScanMode: String, Sendable, CaseIterable {
    case burst, lookAlikes, similarSets

    /// Max dHash Hamming distance. For burst frames: generous enough to keep
    /// real bursts (slight motion) together, tight enough to split unrelated shots.
    public var dHashDistance: Int {
        switch self {
        case .burst, .similarSets: return 14
        case .lookAlikes: return 8
        }
    }

    /// Burst uses this for its confident gate; cross-time modes use it to group.
    /// Burst: before a frame is *ever* pre-marked for deletion, the cluster must
    /// also be neurally near-identical, not just dHash-close (dHash can't tell
    /// "same framing, subject moved" from a true duplicate); a moved-subject pair
    /// (≈0.2+) falls to "you decide". Tight on purpose — wrongly deleting a keeper
    /// breaks trust, while missing a duplicate is harmless. Similar sets use the
    /// "same scene, different moment" band, looser than look-alikes (≈identical
    /// only), so pose/angle changes still group (cats ≈0.3 land here).
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
        // Clustering knobs (match the Python defaults).
        public static let gapSec = 3.0
        public static let sizeTol = 0.10
        public static let maxSpan = 30.0
        /// A cluster whose internal spread is at most this is a confident,
        /// near-identical burst (pre-marked for deletion). Tuned on real avalanche
        /// bursts: median spread 3, p75 6 — so ≤6 captures ~86% of genuine
        /// held-shutter bursts while pose/subject changes (≈12) fall to "you decide".
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
