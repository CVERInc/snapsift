import Foundation
import Photos

/// A Photos caption describes its asset when it holds anything beyond whitespace
/// (the macOS sidecar's trimmed title/description rule). nil, "" and
/// whitespace-only captions describe nothing.
public func photoCaptionDescribesAsset(_ caption: String?) -> Bool {
    guard let caption else { return false }
    return !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Turns one batch read into description facts. `read` returns the
/// `(id, caption)` entries it could read, or nil when the read failed.
/// An id the read did not return stays absent and a failed read yields nil:
/// undetermined facts carry unique metadata, so a failure is never reported
/// as "no caption".
public func photoCaptionDescriptions(
    for ids: [String],
    read: ([String]) async -> [(id: String, caption: String?)]?
) async -> [String: Bool]? {
    guard let entries = await read(ids) else { return nil }
    var facts: [String: Bool] = [:]
    for entry in entries { facts[entry.id] = photoCaptionDescribesAsset(entry.caption) }
    return facts
}

// `PHAssetExtendedMetadata` is declared by the Xcode 27 SDK (Swift 6.4); the
// Swift 5.10 CI toolchain does not compile this block.
#if compiler(>=6.4)
/// Reads the Photos caption of each id from the library. Pass it as
/// `PhotoLibrarySession(descriptionSource:)` on a platform without an
/// enrichment port. nil when the lane times out or its breaker is tripped.
@available(iOS 27, macOS 27, *)
public func photoKitCaptionDescriptions(for ids: [String]) async -> [String: Bool]? {
    await photoCaptionDescriptions(for: ids) { ids in
        await PhotoKitSyncLane.call {
            // Fetched fresh on every read: a PHAsset whose extendedMetadata was
            // already read keeps its old caption, so scan-time assets are not reused.
            // Prefetch measured ~2.3 ms vs ~3 ms per 2-3-id batch on the simulator.
            let options = PHFetchOptions()
            options.prefetchAssetExtendedMetadata = true
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
            var entries: [(id: String, caption: String?)] = []
            fetched.enumerateObjects { asset, _, _ in
                entries.append((asset.localIdentifier, asset.extendedMetadata.caption))
            }
            return entries
        }
    }
}
#endif
