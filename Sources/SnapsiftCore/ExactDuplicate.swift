import Foundation

// MARK: - Exact-duplicate predicate

/// The strict bar for "these two images are genuinely interchangeable" —
/// re-imports, saves-twice, or identical copies. Nothing less earns a
/// "suggest delete" affordance.
///
/// Three conditions must ALL be true:
///   1. Same pixel dimensions (width × height). A crop or resize → not exact.
///   2. dHash Hamming distance == 0. A single differing bit means something
///      changed perceptually — JPEG re-compression noise, a watermark,
///      a caption overlay. Distance 1+ is "very similar", not exact.
///   3. Neural feature-print distance ≈ 0. This is the redundant confirmation
///      gate: dHash is fast but coarse; the feature print is precise. We require
///      both so that a solid-colour image (dHash always 0) or a lucky hash
///      collision can never alone qualify. The `featureThreshold` is intentionally
///      near-zero (not the 0.10 confident-burst gate) because we need certainty,
///      not confidence.
///
/// Normal bursts, poses, zoom-steps, and HDR brackets do NOT qualify —
/// they go to the review bucket only, never the "suggest delete" path.
public struct ExactDuplicatePredicate {
    /// Hamming distance at or below which two dHashes count as perceptually
    /// identical. 0 means bit-for-bit equal hashes — the strict bar.
    public static let hammingThreshold: Int = 0

    /// Max feature-print distance that may accompany a hamming-0 match. Set
    /// deliberately near-zero: a normal burst easily stays above 0.03 even
    /// when dHash agrees, so this safely separates re-saved copies from motion.
    public static let featureThreshold: Float = 0.02

    /// True when two frames meet the exact-duplicate bar:
    ///   - same dimensions AND
    ///   - dHash Hamming distance == 0 AND
    ///   - feature-print distance ≤ featureThreshold
    ///
    /// `hammingDistance`: result of `hamming(hashA, hashB)`
    /// `featureDistance`: result of `VNFeaturePrintObservation.computeDistance`
    /// `sameSize`:        `a.width == b.width && a.height == b.height`
    public static func isExactDuplicate(
        hammingDistance: Int,
        featureDistance: Float,
        sameSize: Bool
    ) -> Bool {
        sameSize
            && hammingDistance == hammingThreshold
            && featureDistance <= featureThreshold
    }
}

// MARK: - Exact-duplicate group precheck

/// Pixel-free eligibility check a group must pass BEFORE the perceptual and
/// byte gates even run:
///   - at least two members,
///   - no videos (a single poster frame is not an identity test),
///   - one single UTI (a RAW+JPEG or original+re-export pair from the same
///     capture is never interchangeable, however identical it looks),
///   - identical pixel dimensions across all members.
public func exactGroupPrecheck(_ group: [Photo]) -> Bool {
    guard group.count >= 2 else { return false }
    guard !group.contains(where: { $0.kind == 1 }) else { return false }
    guard Set(group.map(\.uti)).count == 1 else { return false }
    let w0 = group[0].width, h0 = group[0].height
    return group.allSatisfy { $0.width == w0 && $0.height == h0 }
}

// MARK: - Exact-duplicate suggestions

/// Within a confirmed exact-duplicate group, the frames that MAY be suggested
/// for deletion: the non-keeper, non-protected members.
///
/// Protection is absolute: a protected frame (`Photo.isProtected`) is NEVER
/// in this set, even if it is not the keeper — the same guarantee as
/// `deletions()` in Keeper.swift. Only exact-duplicate groups should call
/// this; for any other group it returns an empty array.
public func exactDuplicateSuggestions(_ group: [Photo]) -> [Photo] {
    guard group.count >= 2 else { return [] }
    let keep = keeper(group)
    return group.filter { $0.uuid != keep.uuid && !$0.isProtected }
}
