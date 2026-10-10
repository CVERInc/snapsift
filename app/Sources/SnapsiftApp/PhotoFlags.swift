import Foundation
import Photos
import SnapsiftPhotoKit

/// Photos-only metadata flags. Pixel analysis lives in SnapsiftVision.PhotoFlags.
enum PhotoKitFlags {

    // MARK: - `edited` via PhotoKit — FALLBACK ONLY (sidecar unavailable)

    /// True when the user applied adjustments to this asset — PhotoKit path.
    ///
    /// We rely on the reliable PUBLIC PhotoKit signals, NOT `modificationDate !=
    /// creationDate` — iCloud sync, metadata writes (favoriting, captioning),
    /// face/scene reprocessing and library migrations all bump modificationDate
    /// without any user edit, so that heuristic would wrongly flag (here: over-
    /// protect — harmless) AND, worse, would be noise we can't trust. Instead:
    ///   1. `PHAssetResource.assetResources(for:)` contains a resource of type
    ///      `.adjustmentData` once an edit has been committed (any editor —
    ///      Photos' own crop/filter or a third-party extension writes it). This
    ///      is the canonical "this asset carries edit data" signal.
    ///   2. `PHAsset.adjustmentFormatIdentifier` (macOS 12+) is non-nil for an
    ///      edited asset — a cheap corroborating signal, OR-ed in.
    ///
    /// ⚠️ Both signals are SYNCHRONOUS XPC round-trips into photolibraryd with
    /// no timeout of their own. If the daemon restarts mid-call the reply never
    /// arrives and the calling thread wedges FOREVER — and because the fetch
    /// funnels through the one shared library CoreData queue, every later
    /// PhotoKit metadata call convoys behind it (live incident 2026-07-03: a
    /// scan hung >24 h with all 8 enrich workers — the entire Swift-concurrency
    /// cooperative pool — blocked behind one wedged call). NEVER call this from
    /// a concurrency task; go through `editedFallback`. The primary source for
    /// `edited` is the sidecar's `ZASSET.ZADJUSTMENTSSTATE` (semantically
    /// identical, zero XPC — see `QualitySidecar`).
    private static func editedViaPhotoKit(_ asset: PHAsset) -> Bool {
        if asset.adjustmentFormatIdentifier != nil { return true }
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.contains { $0.type == .adjustmentData }
    }

    /// Wedge-proof wrapper around `editedViaPhotoKit`, for when the sidecar is
    /// unreadable (no Full Disk Access) — see `PhotoKitSyncLane` for the
    /// machinery. nil = could not determine (timed out, or the lane's breaker
    /// already tripped): callers keep their stored value (protection simply
    /// isn't upgraded — the safe direction for a best-effort signal).
    static func editedFallback(_ asset: PHAsset) async -> Bool? {
        await PhotoKitSyncLane.call { editedViaPhotoKit(asset) }
    }

    // MARK: - cheap, metadata-only (no pixels)

    /// True when the frame still carries original camera-capture metadata (EXIF
    /// Make/Model) rather than an EXIF-stripped social re-save.
    ///
    /// TODO(slice-1): reliable EXIF Make/Model is not cheaply available in the
    /// current Photo-building path. Reading it means
    /// `requestImageDataAndOrientation` (full image data → CGImageSource EXIF),
    /// which with `isNetworkAccessAllowed = false` returns nil for iCloud-evicted
    /// originals and is expensive per asset. Rather than ship a half-working
    /// heuristic that could mis-rank keepers, we leave this defaulting to `false`
    /// for now. Because it is purely a RANKING tiebreaker (never a delete
    /// trigger), a uniform `false` is safe: it just falls through to the existing
    /// format/size/earliest signals, exactly as before this slice. A pending
    /// Swift test (`original-camera ranking, pending real EXIF`) documents the
    /// intended behaviour for when this is wired.
    static func originalCamera(_ asset: PHAsset) -> Bool {
        false   // see TODO above — pending reliable on-device EXIF Make/Model
    }

}
