import SwiftUI
import Photos

/// Loads a PHAsset thumbnail via PHImageManager — so it works even when the
/// original has been evicted by iCloud "Optimize Storage" (it fetches on
/// demand). High-quality delivery means the continuation resumes exactly once.
struct AssetThumbnail: View {
    let asset: PHAsset?
    let manager: PHCachingImageManager
    var side: CGFloat = 150

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color.reefDeep)
                ProgressView().controlSize(.small).tint(.reefMint)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: asset?.localIdentifier) { await load() }
    }

    private func load() async {
        guard let asset else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true        // pull from iCloud if evicted
        opts.deliveryMode = .highQualityFormat    // single callback
        opts.resizeMode = .fast
        let target = CGSize(width: side * 2, height: side * 2)
        let result: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFill, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
        if let result { image = result }
    }
}
