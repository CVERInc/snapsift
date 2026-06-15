import Foundation

/// UTI keep-priority — higher wins. Mirrors Python `pick.UTI_PRIORITY`.
public let utiPriority: [String: Int] = [
    "public.heic": 100,
    "public.heif": 100,
    "public.jpeg": 80,
    "public.png": 60,
    "public.tiff": 50,
    "com.compuserve.gif": 20,
    "public.mpeg-4": 70,
    "com.apple.quicktime-movie": 70,
]

/// Quantise a quality score to integer tenths with deterministic, platform-
/// independent round-half-up — `floor(q*10 + 0.5)`. This is the SAME rule the
/// Python CLI uses (`pick.quality_bucket`), NOT Swift's default round-half-away
/// `.rounded()`, so the app and the CLI always agree on the keeper. Quantising
/// means noise-level quality differences fall through to format/size.
public func qualityBucket(_ quality: Double) -> Int { Int((quality * 10 + 0.5).rounded(.down)) }

/// Sort key for "most worth keeping" — higher is better. Favorites first, then
/// Apple's quality score quantised to 1 decimal (so noise-level differences
/// don't override the format/size signal), then UTI priority, file size, and
/// finally the earliest take. Mirrors Python `pick.rank`.
public func rankKey(_ p: Photo) -> (Int, Int, Int, Int, Double) {
    (p.favorite ? 1 : 0,
     qualityBucket(p.quality),
     utiPriority[p.uti] ?? 0,
     p.size,
     -p.takenAt)
}

/// The single frame to keep from a cluster.
public func keeper(_ group: [Photo]) -> Photo {
    group.max { rankKey($0) < rankKey($1) }!
}

/// UUIDs to delete from a cluster: everything that is neither the keeper nor a
/// favorite. Favorites are sacred — an all-favorite cluster deletes nothing.
public func deletions(_ group: [Photo]) -> [Photo] {
    let keep = keeper(group)
    return group.filter { $0.uuid != keep.uuid && !$0.favorite }
}
