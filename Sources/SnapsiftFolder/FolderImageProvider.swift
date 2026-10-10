import Foundation
import CoreGraphics
import ImageIO
import SnapsiftVision

/// ImageIO reads only local file URLs and applies EXIF orientation. Deadlines
/// bound the caller's wait; at most eight decodes can remain in flight if an
/// OS/file decoder blocks. Blocking ImageIO never runs on the cooperative pool.
public final class FolderImageProvider: ImageProvider, @unchecked Sendable {
    public let itemIdentifiers: Set<String>
    private let primaryURLs: [String: URL]
    private let queue = DispatchQueue(label: "net.cver.snapsift.folder-images",
                                      qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = 0

    public init(items: [FolderItem]) {
        primaryURLs = Dictionary(items.map { ($0.id, $0.primary.url) },
                                 uniquingKeysWith: { first, _ in first })
        itemIdentifiers = Set(primaryURLs.keys)
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGImage?, Never>?
        private var timeout: DispatchWorkItem?
        init(_ continuation: CheckedContinuation<CGImage?, Never>) {
            self.continuation = continuation
        }
        func finish(_ image: CGImage?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            let timer = timeout
            timeout = nil
            lock.unlock()
            timer?.cancel()
            pending?.resume(returning: image)
        }

        func startTimeout(seconds: TimeInterval) {
            let timer = DispatchWorkItem { self.finish(nil) }
            lock.lock(); timeout = timer; lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
        }
    }

    public func image(for itemIdentifier: String, profile: ImageRequestProfile) async -> CGImage? {
        guard !Task.isCancelled, let url = primaryURLs[itemIdentifier], url.isFileURL else { return nil }
        let (side, seconds) = Self.settings(profile)
        guard reserve() else { return nil }
        return await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            reply.startTimeout(seconds: seconds)
            queue.async {
                let image = Self.thumbnail(at: url, side: side)
                self.release()
                reply.finish(image)
            }
        }
    }

    private static func thumbnail(at url: URL, side: Int) -> CGImage? {
        // Re-read rather than trusting enumeration's cached resource values.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard (try? freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
            .map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                                                     [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inFlight < 8 else { return false }
        inFlight += 1
        return true
    }

    private func release() {
        lock.lock(); defer { lock.unlock() }
        inFlight -= 1
    }

    private static func settings(_ profile: ImageRequestProfile) -> (Int, TimeInterval) {
        switch profile {
        case .dHash: return (9, 2)
        case .featurePrint: return (160, 2)
        case .faceScoring: return (512, 10)
        case .categoryLabels: return (256, 10)
        case .documentLocal: return (512, 2)
        case .documentHighQuality: return (512, 30)
        }
    }
}
