import Foundation
import Photos
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SnapsiftCore

// MARK: - Pass 2b — Save rotation to Photos (reversible)
//
// This file owns the ONLY write path that modifies photo content in snapsift.
// All prior writes were destructive (deletion via PHAssetChangeRequest.deleteAssets).
// This is the first CONTENT-EDITING write: it uses PHContentEditingOutput +
// PHAdjustmentData so Photos retains the original and surfaces "Revert to
// Original" in the Photos app — the user can undo this at any time.
//
// Quality trade-off (documented honestly):
//   We output JPEG at 0.95 quality. HEIC output requires AVAssetExportSession
//   with an AVVideoSettings codec setup that is not available in the
//   PHContentEditingOutput context without additional entitlements. The original
//   HEIC/RAW is always preserved by Photos regardless, so the rendered copy is
//   a high-quality JPEG re-encode. This is the same trade-off Photos.app itself
//   makes for many third-party extension adjustments.
//
// Pure encode/decode helpers (encodeQuarterTurns / decodeQuarterTurns) live in
// SnapsiftCore/RotationEncoding.swift so the framework-free test runner can
// cover them without pulling in PhotoKit.

// MARK: - CIImage rotation helpers

/// Maps a quarter-turn count to the CGAffineTransform that rotates a CIImage
/// clockwise by `quarterTurns * 90°`. CIImage uses a Y-up coordinate system, so
/// we rotate counter-clockwise in standard math to achieve clockwise visual.
/// (0 → identity, 1 → 90° CW, 2 → 180°, 3 → 270° CW)
func ciRotationTransform(for quarterTurns: Int) -> CGAffineTransform {
    let net = ((quarterTurns % 4) + 4) % 4
    // Negative angle = clockwise in CIImage Y-up space.
    let angle = -Double(net) * (.pi / 2.0)
    return CGAffineTransform(rotationAngle: angle)
}

/// Apply `quarterTurns` of clockwise rotation to `cgImage` using CIImage and
/// return the result as a CGImage rendered in `ciContext`.
/// Returns nil if the rotation or render fails.
func applyRotation(quarterTurns: Int, to cgImage: CGImage, in ciContext: CIContext) -> CGImage? {
    let net = ((quarterTurns % 4) + 4) % 4
    guard net != 0 else { return cgImage }

    // Load as CIImage — CIImage coordinates are Y-up, origin bottom-left.
    let ci = CIImage(cgImage: cgImage)
    let transform = ciRotationTransform(for: net)

    // The rotation leaves the image translated off-origin.
    // Translate back so the result starts at (0,0).
    let rotated = ci.transformed(by: transform)
    let translated = rotated.transformed(
        by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                              y: -rotated.extent.origin.y)
    )

    let extent = translated.extent
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    return ciContext.createCGImage(translated, from: extent, format: .RGBA8, colorSpace: colorSpace)
}

// MARK: - Save errors

enum RotationSaveError: LocalizedError {
    case noEditingInput
    case noSourceImage
    case renderFailed
    case photoKitWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noEditingInput:
            return "Couldn't get editing access to this photo. Try again, or check that snapsift has Full Photos access."
        case .noSourceImage:
            return "Couldn't load the full-size original. The photo may still be downloading from iCloud."
        case .renderFailed:
            return "Couldn't render the rotated image."
        case .photoKitWriteFailed(let underlying):
            return "Photos couldn't save the rotation: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - PhotoKit write

/// Save a clockwise quarter-turn rotation permanently to Photos for `asset`.
///
/// This is REVERSIBLE: Photos stores the original and writes `PHAdjustmentData`
/// with formatIdentifier "net.cver.snapsift.rotate". The user can choose
/// "Revert to Original" in the Photos app at any time.
///
/// Network access IS allowed (`isNetworkAccessAllowed = true`) because:
///   - This is an explicit, user-initiated single-photo action.
///   - We need the full-size original, which may be iCloud-optimised.
///   - This contrasts with the scan path (all offline, never network).
///
/// After a successful save, the photo will be marked as edited
/// (PHAdjustmentData present, and the library's ZADJUSTMENTSSTATE flips with
/// it), so the sidecar-backed `edited` flag reads true and snapsift will
/// treat this frame as protected. This is correct and expected — the UI
/// informs the user before they confirm.
func saveRotation(asset: PHAsset, quarterTurns: Int) async throws {
    let net = ((quarterTurns % 4) + 4) % 4
    guard net != 0 else { return }  // 0 or 360° → nothing to save

    // Step 1: Request content-editing input with network access.
    let options = PHContentEditingInputRequestOptions()
    options.isNetworkAccessAllowed = true  // fetch iCloud-evicted originals

    let editingInput: PHContentEditingInput = try await withCheckedThrowingContinuation { cont in
        asset.requestContentEditingInput(with: options) { input, info in
            if let input {
                cont.resume(returning: input)
            } else {
                // info[PHContentEditingInputResultIsInCloudKey] == true means it's
                // iCloud-only and couldn't be fetched even with network allowed.
                cont.resume(throwing: RotationSaveError.noEditingInput)
            }
        }
    }

    // Step 2: Load full-size image URL.
    guard let url = editingInput.fullSizeImageURL else {
        throw RotationSaveError.noSourceImage
    }

    // Step 3: Load CIImage respecting EXIF orientation so the source image
    // is already upright before we apply our additional rotation.
    // `applyOrientationProperty: true` bakes the EXIF orientation into pixels
    // so we're always rotating from the visually-correct upright state.
    let sourceCI = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    guard let sourceCI else {
        throw RotationSaveError.noSourceImage
    }

    // Step 4: Render the source CIImage + rotation to a CGImage.
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Apply quarter-turn rotation.
    let transform = ciRotationTransform(for: net)
    let rotatedCI = sourceCI.transformed(by: transform)
    // Translate to origin (rotation may leave negative coordinates).
    let translated = rotatedCI.transformed(
        by: CGAffineTransform(translationX: -rotatedCI.extent.origin.x,
                              y: -rotatedCI.extent.origin.y)
    )

    guard let rotatedCG = ciContext.createCGImage(translated, from: translated.extent,
                                                   format: .RGBA8, colorSpace: colorSpace) else {
        throw RotationSaveError.renderFailed
    }

    // Step 5: Encode rotated CGImage to JPEG at 0.95 quality via ImageIO —
    // platform-neutral (no AppKit/UIKit). HEIC output is not available in
    // PHContentEditingOutput without additional AVFoundation setup; JPEG at
    // 0.95 gives visually lossless results and the original HEIC/RAW is
    // always preserved by Photos regardless.
    let jpegBuffer = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(jpegBuffer, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw RotationSaveError.renderFailed
    }
    CGImageDestinationAddImage(dest, rotatedCG,
                               [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw RotationSaveError.renderFailed
    }
    let jpegData = jpegBuffer as Data

    // Step 6: Build PHContentEditingOutput.
    let output = PHContentEditingOutput(contentEditingInput: editingInput)

    // Adjustment data: formatIdentifier is the canonical "who made this edit"
    // signal. Photos uses this to surface "Revert to Original" and to know
    // whether an app can handle re-editing its own output.
    // We encode the net quarter-turns so a future version of snapsift could
    // read it back and offer to rotate again (canHandleAdjustmentData would
    // check formatIdentifier == "net.cver.snapsift.rotate").
    let adjustmentData = PHAdjustmentData(
        formatIdentifier: "net.cver.snapsift.rotate",
        formatVersion: "1.0",
        data: encodeQuarterTurns(net)
    )
    output.adjustmentData = adjustmentData

    // Write the rendered JPEG to the output's renderedContentURL.
    do {
        try jpegData.write(to: output.renderedContentURL, options: .atomic)
    } catch {
        throw RotationSaveError.renderFailed
    }

    // Step 7: Commit via PHPhotoLibrary.
    do {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }
    } catch {
        throw RotationSaveError.photoKitWriteFailed(error)
    }
}
