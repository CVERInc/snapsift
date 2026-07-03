import Foundation
import Photos
import CryptoKit

/// SHA-256 over an asset's original file, streamed via PHAssetResourceManager.
/// Used as the final, non-perceptual gate of the exact-duplicate pass: a
/// "suggest delete" verdict is only issued when originals are byte-identical.
///
/// Never touches the network (`isNetworkAccessAllowed = false`): an
/// iCloud-evicted original returns nil, and nil means "cannot verify" — the
/// caller must treat that as NOT exact, never download gigabytes to find out.
enum OriginalHasher {

    /// Streaming hash box so the escaping data handler can accumulate chunks.
    private final class HashBox: @unchecked Sendable {
        private var hasher = SHA256()
        private let lock = NSLock()
        func update(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            hasher.update(data: data)
        }
        func finalizeHex() -> String {
            lock.lock(); defer { lock.unlock() }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Hex SHA-256 of the asset's primary original resource, or nil when the
    /// original is unavailable locally, the read fails, OR the asset carries
    /// more than its primary still — in which case hashing that one resource
    /// would falsely certify interchangeability the byte gate never proved.
    static func sha256(asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        // A multi-resource asset is NEVER interchangeable with a single-resource
        // still even when the primary photo bytes match — the very rationale
        // `exactGroupPrecheck` states for RAW+JPEG. We hash only the primary
        // resource, so a Live Photo (paired video), a RAW+JPEG (.alternatePhoto),
        // or any companion-carrying asset would digest EQUAL to a motion/RAW-
        // stripped copy and be pre-marked exact, silently discarding the extra
        // half on delete. Return nil ("cannot verify" → NOT exact) so such assets
        // still appear in ordinary review buckets but are never auto-seeded.
        if asset.mediaSubtypes.contains(.photoLive) { return nil }
        guard resources.filter({ $0.type != .adjustmentData }).count <= 1 else { return nil }
        // Prefer the true original still; fall back to the first resource so
        // re-imports whose only resource is e.g. .fullSizePhoto still hash.
        guard let res = resources.first(where: { $0.type == .photo })
                ?? resources.first else { return nil }
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = false
        let box = HashBox()
        return await withCheckedContinuation { cont in
            PHAssetResourceManager.default().requestData(
                for: res, options: opts,
                dataReceivedHandler: { box.update($0) },
                completionHandler: { error in
                    cont.resume(returning: error == nil ? box.finalizeHex() : nil)
                }
            )
        }
    }
}
