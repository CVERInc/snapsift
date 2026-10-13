import Foundation

/// Single-pass time-burst clustering — a 1:1 port of Python `scan.cluster`.
///
/// A photo joins the current cluster iff it shares `(width, height)` with the
/// previous frame, falls within `gapSec` of it, is within `sizeTol` relative
/// file-size, and keeps the whole cluster inside `maxSpan` total seconds
/// (`maxSpan <= 0` disables the span cap). Clusters of fewer than two frames
/// are dropped. Input is assumed sorted by `takenAt` ascending.
public func cluster(_ photos: [Photo],
                    gapSec: Double,
                    sizeTol: Double,
                    maxSpan: Double = 0) -> [[Photo]] {
    var groups: [[Photo]] = []
    var current: [Photo] = []

    for p in photos {
        if let prev = current.last, let first = current.first {
            let gap = p.takenAt - prev.takenAt
            let sizeOK = prev.size == 0 || p.size == 0
                || abs(Double(p.size - prev.size)) / Double(prev.size) < sizeTol
            let spanOK = maxSpan <= 0 || (p.takenAt - first.takenAt) <= maxSpan
            if gap < gapSec
                && p.width == prev.width
                && p.height == prev.height
                && sizeOK
                && spanOK {
                current.append(p)
                continue
            }
            if current.count >= 2 { groups.append(current) }
            current = [p]
        } else {
            current = [p]
        }
    }
    if current.count >= 2 { groups.append(current) }
    return groups
}

/// Fold Apple's per-trait aesthetic scores into a single number; `nil` traits
/// count as zero. Positive traits add, failure/noise subtract. Mirrors
/// Python `scan.quality_score`, rounded to 4 decimals.
public func qualityScore(positive: [Double?], negative: [Double?]) -> Double {
    let pos = positive.compactMap { $0 }.reduce(0, +)
    let neg = negative.compactMap { $0 }.reduce(0, +)
    return ((pos - neg) * 10_000).rounded() / 10_000
}
