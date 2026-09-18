import SwiftUI

// Cross-platform image bridging. PHImageManager hands back NSImage on macOS
// and UIImage on iOS; everything downstream only ever needs a CGImage (for
// Vision/dHash) or a SwiftUI Image (for display). These shims are the only
// place the app names either class, so every scanner and view stays
// platform-clean for the iPhone build.
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage

extension NSImage {
    /// CGImage for Vision / pixel work (name avoids clashing with UIKit's `cgImage`).
    var cgImageForProcessing: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

extension Image {
    init(platform image: PlatformImage) { self.init(nsImage: image) }
}
#else
import UIKit
typealias PlatformImage = UIImage

extension UIImage {
    var cgImageForProcessing: CGImage? { cgImage }
}

extension Image {
    init(platform image: PlatformImage) { self.init(uiImage: image) }
}
#endif

extension View {
    /// Desktop windows get the 820×560 floor the review layout was designed
    /// for; iPhone lays out to the device and must not be forced wider.
    @ViewBuilder func desktopMinimumFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 820, minHeight: 560)
        #else
        self
        #endif
    }

    /// Sheet sizing: fixed frames on macOS; iPhone sheets are full-screen and
    /// must never be forced wider than the device.
    @ViewBuilder func desktopSheetFrame(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                                        maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight)
        #else
        self
        #endif
    }
}
