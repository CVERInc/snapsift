import Foundation

/// Original bytes, never a perceptual digest. nil means identity is unverified.
public protocol OriginalBytesHasher {
    func sha256(itemIdentifier: String) async -> String?
}

/// Source-specific non-pixel facts; undetermined fields stay nil (protective).
public protocol UniqueMetadataProbe {
    func metadata(for itemIdentifiers: [String]) async -> [String: LibraryMetadata]
}

public struct ExactRejectionResult {
    public let groups: [ReviewGroup]
    public let uniqueMetadataWithheld: Int
    public let uniqueMetadataIDs: Set<String>
}

/// Source-independent exact verification and suggestion rules. Pixel analysis
/// and source effects enter through ports; all protection defaults stay in Core.
/// Retains the original model's executor for decisions and progress callbacks.
@MainActor
public enum ExactDuplicatePass {
    public static func detectExactDuplicates(
        in snapshot: [ReviewGroup],
        hasher: any OriginalBytesHasher,
        dHashes: ([String]) async -> [String: UInt64],
        featureSpread: ([String]) async -> Float?,
        isCancelled: () -> Bool = { false },
        progress: (Int, Int) -> Void = { _, _ in },
        onFinished: () -> Void = {}
    ) async -> Set<ReviewGroup.ID> {
        guard !snapshot.isEmpty else { return [] }
        progress(0, snapshot.count)

        var exact: Set<ReviewGroup.ID> = []
        var done = 0
        for g in snapshot {
            if Task.isCancelled || isCancelled() { return exact }   // caller bails + cleans up
            defer {
                done += 1
                if done % 10 == 0 {
                    progress(done, snapshot.count)
                }
            }

            // 0+1. Pixel-free eligibility (member count, no videos, single UTI,
            // matching dimensions) — pure Core predicate, unit-tested.
            guard exactGroupPrecheck(g.photos) else { continue }

            // 2. dHash distance == 0 for ALL pairs (computed in Core — no I/O).
            //    We need thumbnails; request them with bounded concurrency.
            let ids = g.photos.map(\.uuid)
            let hashes = await dHashes(ids)
            guard hashes.count == ids.count else { continue }
            let hashValues = ids.compactMap { hashes[$0] }
            guard hashValues.count == ids.count else { continue }
            var allZero = true
            outer: for i in 0..<hashValues.count {
                for j in (i + 1)..<hashValues.count {
                    if hamming(hashValues[i], hashValues[j]) > ExactDuplicatePredicate.hammingThreshold {
                        allZero = false; break outer
                    }
                }
            }
            guard allZero else { continue }

            // 3. Feature-print distance ≤ featureThreshold for ALL pairs.
            guard let spread = await featureSpread(ids),
                  spread <= ExactDuplicatePredicate.featureThreshold else { continue }

            // 4. Byte verification: every member's original must hash identically.
            //    Any unreadable/evicted original → cannot verify → not exact.
            var digests: Set<String> = []
            var verifiable = true
            for id in ids {
                guard let d = await hasher.sha256(itemIdentifier: id) else {
                    verifiable = false
                    break
                }
                digests.insert(d)
            }
            guard verifiable, digests.count == 1 else { continue }

            exact.insert(g.id)
        }

        onFinished()
        return exact
    }

    /// Only byte-confirmed groups enter this pass. A hi-Q document result of
    /// nil withholds the suggestion; true upgrades the shared protection flag.
    public static func seedExactRejections(
        in built: [ReviewGroup],
        exact: Set<ReviewGroup.ID>,
        metadataProbe: any UniqueMetadataProbe,
        documentCheck: (String) async -> Bool?,
        isCancelled: () -> Bool = { false },
        progress: (Int, Int) -> Void = { _, _ in },
        onMetadataWithheld: (String, Bool) -> Void = { _, _ in }
    ) async -> ExactRejectionResult {
        var withheld = 0
        var metadataIDs: Set<String> = []
        guard !exact.isEmpty else {
            return ExactRejectionResult(groups: built, uniqueMetadataWithheld: withheld,
                                        uniqueMetadataIDs: metadataIDs)
        }
        var built = built
        // Report progress: the hi-q document re-check below suspends up to 30 s
        // per candidate, so on a big library this tail can run minutes — it must
        // keep the scan's single progress surface alive, not blank out.
        let total = exact.count
        var done = 0
        progress(0, total)
        for i in built.indices where exact.contains(built[i].id) {
            if Task.isCancelled || isCancelled() {   // caller bails + cleans up
                return ExactRejectionResult(groups: built, uniqueMetadataWithheld: withheld,
                                            uniqueMetadataIDs: metadataIDs)
            }
            defer {
                done += 1
                progress(done, total)
            }
            let keeperID = built[i].keeperID
            var seeds: Set<String> = []
            // Byte-identical is an answer about PIXELS. It is not an answer
            // about the LIBRARY ENTRY: the copy we would suggest removing may be
            // the one the user captioned and filed into three albums, and the
            // two thumbnails in the sheet are literally the same image, so they
            // cannot catch it. Compare what each copy carries first; anything
            // the probe cannot determine counts as "carries" (Core
            // `carriesUniqueMetadata`) and the frame is simply not pre-marked —
            // the group keeps its exact badge and stays the user's to decide.
            let metadata = await metadataProbe.metadata(for: built[i].photos.map(\.uuid))
            let keeperMeta = metadata[keeperID] ?? LibraryMetadata()
            for (j, p) in built[i].photos.enumerated() {
                guard p.uuid != keeperID, p.isDeletable else { continue }
                if carriesUniqueMetadata(candidate: metadata[p.uuid] ?? LibraryMetadata(),
                                         keeper: keeperMeta) {
                    withheld += 1
                    // Only badge what we could actually READ: an undetermined
                    // probe justifies withholding the pre-mark, but claiming
                    // "carries a caption" about a frame we couldn't read would
                    // be inventing a fact on the confirmation surface.
                    if (metadata[p.uuid] ?? LibraryMetadata()).isFullyDetermined {
                        metadataIDs.insert(p.uuid)
                    }
                    onMetadataWithheld(p.uuid, (metadata[p.uuid] ?? LibraryMetadata()).isFullyDetermined)
                    continue
                }
                switch await documentCheck(p.uuid) {
                case .some(true):
                    // Real document — upgrade the frame's flag so the UI
                    // badge and every downstream guard agree.
                    built[i].photos[j] = built[i].photos[j]
                        .with(isDocument: true, documentEvalDegraded: false)
                    continue
                case .none:
                    continue   // couldn't verify — stay protective, don't seed
                case .some(false):
                    break      // verified not a document — safe to seed
                }
                seeds.insert(p.uuid)
            }
            built[i].rejected.formUnion(seeds)
            built[i].autoSeeded = seeds
        }
        return ExactRejectionResult(groups: built, uniqueMetadataWithheld: withheld,
                                    uniqueMetadataIDs: metadataIDs)
    }
}
