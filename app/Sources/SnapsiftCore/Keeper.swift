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

/// Sort key for "most worth keeping" — higher is better. Favorites first, then
/// Apple's quality score quantised to 1 decimal (so noise-level differences
/// don't override the format/size signal), then UTI priority, file size, and
/// finally the earliest take. Mirrors Python `pick.rank`.
public func rankKey(_ p: Photo) -> (Int, Int, Int, Int, Double) {
    (p.favorite ? 1 : 0,
     Int((p.quality * 10).rounded()),
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
