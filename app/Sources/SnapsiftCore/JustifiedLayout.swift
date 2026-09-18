import Foundation

/// Pure row-packing math for a justified ("Photos.app / Lightroom") gallery:
/// frames keep their TRUE aspect ratio and are laid out in rows of a common
/// target height; each FULL row is then uniformly scaled so its total width
/// exactly fills the container. The last (partial) row keeps the target height
/// rather than being stretched across the whole width.
///
/// This is deliberately UI-free (no SwiftUI) so it can be unit-tested under the
/// framework-free `swift run SnapsiftTests` runner, and so the same math could
/// be reused by the CLI or a future renderer.
public enum JustifiedLayout {

    /// One placed frame: its index into the input `aspectRatios`, plus the final
    /// on-screen `width`/`height` (in points) after the row was justified.
    public struct Placed: Equatable, Sendable {
        public let index: Int
        public let width: Double
        public let height: Double
        public init(index: Int, width: Double, height: Double) {
            self.index = index; self.width = width; self.height = height
        }
    }

    /// One laid-out row: the placed frames plus the row's final height.
    public struct Row: Equatable, Sendable {
        public let items: [Placed]
        public let height: Double
        public init(items: [Placed], height: Double) {
            self.items = items; self.height = height
        }
        /// Total laid-out width including inter-item spacing — used by tests to
        /// assert a justified row fills the container.
        public func totalWidth(spacing: Double) -> Double {
            guard !items.isEmpty else { return 0 }
            return items.reduce(0) { $0 + $1.width } + spacing * Double(items.count - 1)
        }
    }

    /// Pack `aspectRatios` (width / height, each > 0, already orientation-
    /// corrected so a portrait frame is < 1) into justified rows.
    ///
    /// - Parameters:
    ///   - aspectRatios: per-frame width/height. Non-finite / non-positive values
    ///     are clamped to 1 (square) so a missing dimension can never break layout.
    ///   - containerWidth: available content width in points (already inset for
    ///     padding). Values ≤ 0 fall back to a single tall column.
    ///   - targetHeight: the nominal row height in points (e.g. ~200).
    ///   - spacing: horizontal gap between frames in a row.
    ///
    /// Algorithm (greedy, single pass):
    ///   1. Walk frames left→right accumulating `width = targetHeight * aspect`.
    ///   2. When adding the next frame would push the row past `containerWidth`,
    ///      finalize the row WITHOUT it: solve for the height `h` where
    ///         Σ(h * aspect) + spacing == containerWidth, i.e.
    ///         h = (containerWidth - spacing) / Σ(aspect),
    ///      emit each frame at `(h * aspect, h)`, then start a fresh row.
    ///   3. The trailing row is emitted at `targetHeight` (NOT stretched), unless
    ///      it alone already overflows, in which case it is scaled DOWN to fit.
    ///
    /// A single frame wider than the container always gets its own row, scaled
    /// down to fit, so nothing ever overflows horizontally.
    public static func rows(aspectRatios: [Double],
                            containerWidth: Double,
                            targetHeight: Double,
                            spacing: Double = 8) -> [Row] {
        guard !aspectRatios.isEmpty else { return [] }
        let H = max(1, targetHeight)
        let W = containerWidth > 0 ? containerWidth : H   // degenerate → tall col
        let gap = max(0, spacing)

        // Sanitize aspect ratios up front (missing / bad dimension → square).
        let aspects: [Double] = aspectRatios.map { a in
            (a.isFinite && a > 0) ? a : 1
        }

        var rows: [Row] = []
        var current: [Int] = []        // indices in the row being built
        var aspectSum = 0.0            // Σ aspect for the current row

        /// Justify the current row and append it. `stretch` = fill the full width
        /// (a row that filled up); otherwise keep the target height but never
        /// overflow (the trailing row).
        func flush(stretch: Bool) {
            guard !current.isEmpty else { return }
            let n = current.count
            let totalGap = gap * Double(n - 1)
            // Height that makes the row exactly fill the available width.
            let fitted = aspectSum > 0 ? (W - totalGap) / aspectSum : H
            let h: Double = stretch ? max(1, fitted) : max(1, min(H, fitted))
            let placed = current.map { idx in
                Placed(index: idx, width: h * aspects[idx], height: h)
            }
            rows.append(Row(items: placed, height: h))
            current.removeAll(keepingCapacity: true)
            aspectSum = 0
        }

        for i in aspects.indices {
            let a = aspects[i]
            // Projected row width if we add this frame at the target height,
            // including the extra inter-item gap it introduces.
            let projGap = gap * Double(current.count)   // gaps once this is added
            let projWidth = (aspectSum + a) * H + projGap
            if !current.isEmpty && projWidth > W {
                // Adding overflows → finalize the row WITHOUT this frame,
                // justified to fill the width, then start fresh with this one.
                flush(stretch: true)
            }
            current.append(i)
            aspectSum += a
        }
        // Trailing row keeps the target height (not stretched to full width).
        flush(stretch: false)
        return rows
    }

    /// The nominal row height for a container of `containerWidth` points.
    ///
    /// Lives here, not in the view, because TWO callers need the identical
    /// number: the gallery that draws the rows, and the keyboard handler that
    /// walks them. Two copies of this formula would mean ↑/↓ walking a layout
    /// nobody is looking at.
    public static func targetHeight(forWidth containerWidth: Double) -> Double {
        guard containerWidth > 0 else { return 200 }
        // ~200pt baseline; scale gently with width so wide windows breathe.
        return min(260, max(150, containerWidth / 4.2))
    }

    /// Walk exactly ONE ROW up (`delta < 0`) or down (`delta > 0`) from the frame
    /// at `index`, keeping the horizontal position: the answer is the frame in
    /// the neighbouring row whose horizontal span contains this frame's centre
    /// (or, if the rows don't overlap there, the frame whose centre is nearest).
    ///
    /// This is what makes ↑/↓ mean "the photo above / below" rather than
    /// "the previous / next photo" — in a justified gallery the two are the same
    /// thing only by accident, and only in a single-row group.
    ///
    /// Returns `nil` when there is no such row (already on the first/last row),
    /// when `index` isn't placed, or when `delta` is 0 — the caller then leaves
    /// focus where it is rather than inventing a move.
    public static func rowNeighbor(rows: [Row], spacing: Double = 8,
                                   from index: Int, delta: Int) -> Int? {
        guard delta != 0 else { return nil }
        let gap = max(0, spacing)
        // Locate the frame and its horizontal centre within its own row.
        var sourceRow: Int? = nil
        var centre = 0.0
        for (r, row) in rows.enumerated() {
            var x = 0.0
            for item in row.items {
                if item.index == index {
                    sourceRow = r
                    centre = x + item.width / 2
                    break
                }
                x += item.width + gap
            }
            if sourceRow != nil { break }
        }
        guard let from = sourceRow else { return nil }
        let target = from + delta
        guard target >= 0, target < rows.count, !rows[target].items.isEmpty else { return nil }

        // Pick the frame in the target row that sits under (or nearest to) the
        // same horizontal position.
        var x = 0.0
        var best = rows[target].items[0].index
        var bestDistance = Double.greatestFiniteMagnitude
        for item in rows[target].items {
            if centre >= x && centre <= x + item.width { return item.index }
            let d = abs((x + item.width / 2) - centre)
            if d < bestDistance { bestDistance = d; best = item.index }
            x += item.width + gap
        }
        return best
    }
}
