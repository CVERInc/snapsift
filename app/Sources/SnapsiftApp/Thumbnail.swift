import SwiftUI
import Photos
import Signet

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

/// Full-resolution inspector shown on Space. Unlike the scan (which never touches
/// the network), this deliberately fetches the *original* from iCloud at maximum
/// size — with a download %  — and shows the whole frame, pinch-to-zoom and
/// drag-to-pan, so the user can be certain before deciding keep/delete.
struct BigPreview: View {
    let asset: PHAsset?
    let manager: PHCachingImageManager
    let t: L10n
    let onClose: () -> Void

    @State private var image: NSImage?
    @State private var pct: Double = 0
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(pan)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { v in zoom = max(1, min(8, lastZoom * v.magnification)) }
                            .onEnded { _ in
                                lastZoom = zoom
                                if zoom <= 1 { withAnimation { pan = .zero; lastPan = .zero } }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                guard zoom > 1 else { return }
                                pan = CGSize(width: lastPan.width + v.translation.width,
                                             height: lastPan.height + v.translation.height)
                            }
                            .onEnded { _ in lastPan = pan }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if zoom > 1 { zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero }
                            else { zoom = 2; lastZoom = 2 }
                        }
                    }
                    .padding(24)
                    .shadow(radius: 30)
            } else {
                VStack(spacing: 10) {
                    ProgressView(value: pct > 0 && pct < 1 ? pct : nil)
                        .controlSize(.large).tint(.reefMint).frame(width: 160)
                    Text(t.previewLoading(pct)).font(.callout).foregroundStyle(Color.reefTextDim)
                }
            }
        }
        .focusable()
        .onKeyPress { _ in onClose(); return .handled }
        .task(id: asset?.localIdentifier) { await load() }
    }

    private func load() async {
        guard let asset else { return }
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero; image = nil; pct = 0
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true             // deliberate iCloud fetch
        opts.deliveryMode = .highQualityFormat         // single callback
        opts.resizeMode = .none
        opts.progressHandler = { p, _, _, _ in Task { @MainActor in self.pct = p } }
        let result: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: PHImageManagerMaximumSize,
                                 contentMode: .aspectFit, options: opts) { img, _ in
                cont.resume(returning: img)
            }
        }
        if let result { image = result }
    }
}
