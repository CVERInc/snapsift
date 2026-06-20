import SwiftUI
import Photos
import Signet

/// Loads a PHAsset thumbnail via PHImageManager — so it works even when the
/// original has been evicted by iCloud "Optimize Storage" (it fetches on
/// demand). High-quality delivery means the continuation resumes exactly once.
///
/// Pass 2a (FIX 1 — orientation): PHImageManager bakes the asset's EXIF
/// orientation into the returned NSImage, so the bitmap is already UPRIGHT. The
/// old square-crop card (`.aspectFill` + `scaledToFill` + a square frame) hid the
/// true shape and could make a portrait look mis-cropped; we now render TRUE
/// aspect (`.fit`) inside the caller-sized frame and never crop. The `aspectFit`
/// content mode on the request also keeps the WHOLE frame, orientation-true.
///
/// Pass 2a (FIX 3 — non-destructive display-rotate): an optional `quarterTurns`
/// rotates the rendered image 90°·n clockwise for display ONLY. It is never
/// written back to Photos (that is the Pass 2b hook in LibraryModel). The caller
/// sizes the frame to the ROTATED aspect ratio so the layout reflows; this view
/// just spins the upright bitmap inside whatever box it's given.
struct AssetThumbnail: View {
    let asset: PHAsset?
    let manager: PHCachingImageManager
    /// The final ON-SCREEN box for this thumbnail (already in the rotated aspect
    /// for the gallery, or square for the contact-sheet tiles). The view sizes
    /// itself to this box so callers don't need a separate `.frame`.
    let box: CGSize
    /// Display-only clockwise quarter-turns (0…3). Not persisted to Photos.
    var quarterTurns: Int = 0
    /// When true, fill the box (legacy square tiles); when false, fit the true
    /// aspect ratio. The gallery passes an aspect-true box + `fill: true` so the
    /// box is exactly covered with no letterbox.
    var fill: Bool = false

    @State private var image: NSImage?

    /// Normalised quarter-turns 0…3.
    private var turns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// The box the UPRIGHT bitmap must be laid out into BEFORE rotation. For an
    /// odd quarter-turn the on-screen box is rotated, so the pre-rotation box has
    /// its width and height swapped — this is the fix for the classic
    /// "rotationEffect doesn't swap the layout box" trap (the bitmap would
    /// otherwise be fill-cropped against the wrong-shaped box, then spun).
    private var preRotationBox: CGSize {
        (turns == 1 || turns == 3) ? CGSize(width: box.height, height: box.width) : box
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
                    // Lay the upright bitmap into the PRE-rotation (swapped) box…
                    .frame(width: preRotationBox.width, height: preRotationBox.height)
                    .clipped()
                    // …THEN rotate it into the on-screen box. 90°·n clockwise.
                    .rotationEffect(.degrees(Double(turns) * 90))
            } else {
                Rectangle().fill(Color.reefDeep)
                ProgressView().controlSize(.small).tint(.reefMint)
            }
        }
        // Constrain to the final on-screen box (post-rotation).
        .frame(width: box.width, height: box.height)
        .clipped()
        .task(id: asset?.localIdentifier) { await load() }
    }

    private func load() async {
        guard let asset else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true        // pull from iCloud if evicted
        opts.deliveryMode = .highQualityFormat    // single callback
        opts.resizeMode = .fast
        // Request a box big enough for the longest edge (×2 for retina) so neither
        // orientation looks soft; aspectFit keeps the WHOLE upright frame.
        let edge = max(box.width, box.height) * 2
        let target = CGSize(width: edge, height: edge)
        let result: NSImage? = await withCheckedContinuation { cont in
            manager.requestImage(for: asset, targetSize: target,
                                 contentMode: .aspectFit, options: opts) { img, _ in
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
///
/// Pass 2a: the loupe honours the same display-only `quarterTurns` as the grid so
/// a rotated frame stays rotated when you open it full-screen. PhotoKit already
/// returns the bitmap upright (EXIF baked in); this only adds the session rotate.
struct BigPreview: View {
    let asset: PHAsset?
    let manager: PHCachingImageManager
    let t: L10n
    /// Display-only clockwise quarter-turns (0…3). Not persisted to Photos.
    var quarterTurns: Int = 0
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
                // FIX 3: rotate correctly in the loupe too. For an odd quarter-turn
                // the image must be FIT into a box whose axes are swapped relative
                // to the container, THEN rotated — otherwise scaledToFit fits the
                // upright bitmap to the wrong axis and the rotated result is
                // letterboxed/undersized. We read the container with a
                // GeometryReader and size the fit-box with swapped width/height for
                // odd turns. Zoom/pan are applied OUTSIDE the rotation so they stay
                // screen-aligned (drag-right always pans right, regardless of turn).
                GeometryReader { geo in
                    let turns = ((quarterTurns % 4) + 4) % 4
                    let odd = (turns == 1 || turns == 3)
                    // Available area inside the 24pt padding.
                    let avail = CGSize(width: max(1, geo.size.width - 48),
                                       height: max(1, geo.size.height - 48))
                    let fitBox = odd ? CGSize(width: avail.height, height: avail.width) : avail
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: fitBox.width, height: fitBox.height)
                        .rotationEffect(.degrees(Double(turns) * 90))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
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
                    // Inset is handled inside the GeometryReader (avail − 48);
                    // a shadow keeps the frame readable against the dim backdrop.
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
