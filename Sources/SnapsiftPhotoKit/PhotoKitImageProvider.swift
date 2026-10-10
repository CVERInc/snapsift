import Foundation
import Photos
import CoreGraphics
import SnapsiftVision
#if canImport(AppKit)
import AppKit
private typealias PhotoKitImage = NSImage
#else
import UIKit
private typealias PhotoKitImage = UIImage
#endif

/// The Photos adapter retains the scan's asset snapshot and caching manager.
/// UI/metadata consumers may resolve assets here; Vision sees only item IDs.
public final class PhotoKitImageProvider: ImageProvider {
    public let assetsByID: [String: PHAsset]
    public let itemIdentifiers: Set<String>
    private let manager: PHCachingImageManager

    public init(assetsByID: [String: PHAsset], manager: PHCachingImageManager) {
        self.assetsByID = assetsByID
        self.itemIdentifiers = Set(assetsByID.keys)
        self.manager = manager
    }

    public func asset(for itemIdentifier: String) -> PHAsset? { assetsByID[itemIdentifier] }

    public func retaining(_ itemIdentifiers: Set<String>) -> PhotoKitImageProvider {
        PhotoKitImageProvider(assetsByID: assetsByID.filter { itemIdentifiers.contains($0.key) },
                              manager: manager)
    }

    private struct Settings {
        let target: CGSize
        let contentMode: PHImageContentMode
        let network: Bool
        let delivery: PHImageRequestOptionsDeliveryMode
        let resize: PHImageRequestOptionsResizeMode
        let timeoutNs: UInt64
    }

    private func settings(for profile: ImageRequestProfile) -> Settings {
        switch profile {
        case .dHash:
            return Settings(target: CGSize(width: 9, height: 8), contentMode: .aspectFill,
                            network: false, delivery: .opportunistic, resize: .fast,
                            timeoutNs: 2_000_000_000)
        case .featurePrint:
            // 160px fits locally cached thumbnails far more often than 256px.
            return Settings(target: CGSize(width: 160, height: 160), contentMode: .aspectFit,
                            network: false, delivery: .opportunistic, resize: .fast,
                            timeoutNs: 2_000_000_000)
        case .faceScoring:
            return Settings(target: CGSize(width: 512, height: 512), contentMode: .aspectFit,
                            network: true, delivery: .highQualityFormat, resize: .exact,
                            timeoutNs: 10_000_000_000)
        case .categoryLabels:
            return Settings(target: CGSize(width: 256, height: 256), contentMode: .aspectFit,
                            network: true, delivery: .highQualityFormat, resize: .fast,
                            timeoutNs: 10_000_000_000)
        case .documentLocal:
            // 512px: document segmentation and OCR lose signal on tiny images.
            return Settings(target: CGSize(width: 512, height: 512), contentMode: .aspectFit,
                            network: false, delivery: .opportunistic, resize: .fast,
                            timeoutNs: 2_000_000_000)
        case .documentHighQuality:
            // Escalation may download an original; 10s falsely degraded real scans.
            return Settings(target: CGSize(width: 512, height: 512), contentMode: .aspectFit,
                            network: true, delivery: .highQualityFormat, resize: .fast,
                            timeoutNs: 30_000_000_000)
        }
    }

    /// Callback or deadline, first wins. PhotoKit can simply never call back on
    /// an optimized library; the timer must always resume the continuation.
    private final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<PhotoKitImage?, Never>?
        func set(_ c: CheckedContinuation<PhotoKitImage?, Never>) { lock.lock(); cont = c; lock.unlock() }
        func finish(_ img: PhotoKitImage?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: img)
        }
    }

    public func image(for itemIdentifier: String, profile: ImageRequestProfile) async -> CGImage? {
        guard let asset = assetsByID[itemIdentifier] else { return nil }
        let settings = settings(for: profile)
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = settings.network
        // Opportunistic serves whatever is cached locally NOW, even if smaller
        // than requested; fastFormat could wait forever for a forbidden download.
        // As before, the first callback wins, including a nil/degraded callback.
        opts.deliveryMode = settings.delivery
        opts.resizeMode = settings.resize
        opts.version = .current   // the PHImageRequestOptions default in every old call
        let box = ImageBox()
        let img: PhotoKitImage? = await withCheckedContinuation { cont in
            box.set(cont)
            manager.requestImage(for: asset, targetSize: settings.target,
                                 contentMode: settings.contentMode, options: opts) { image, _ in
                box.finish(image)
            }
            Task { try? await Task.sleep(nanoseconds: settings.timeoutNs); box.finish(nil) }
        }
        guard let img else { return nil }
        #if canImport(AppKit)
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return img.cgImage
        #endif
    }
}
