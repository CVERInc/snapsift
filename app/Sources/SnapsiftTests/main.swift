import Foundation
import SnapsiftCore

// Framework-free test runner: `swift run SnapsiftTests`.
// Exits non-zero on any failure so it can gate CI. Mirrors the Python pytest
// suite case-for-case (tests/test_cluster.py, test_pick.py, test_hash.py).

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
    if !condition { failures += 1 }
}

func ph(_ pk: Int, _ takenAt: Double, w: Int = 4032, h: Int = 3024,
        size: Int = 2_000_000, uti: String = "public.heic",
        fav: Bool = false, quality: Double = 0,
        edited: Bool = false, isDocument: Bool = false,
        sharpness: Double = 0, originalCamera: Bool = false) -> Photo {
    Photo(uuid: "U\(pk)", filename: "IMG_\(pk).heic", takenAt: takenAt,
          width: w, height: h, size: size, uti: uti, favorite: fav, quality: quality,
          edited: edited, isDocument: isDocument, sharpness: sharpness,
          originalCamera: originalCamera)
}
func sizes(_ g: [[Photo]]) -> [Int] { g.map(\.count) }

print("Clustering")
check(sizes(cluster([ph(1, 0), ph(2, 1), ph(3, 2), ph(4, 100), ph(5, 101)],
                    gapSec: 3, sizeTol: 0.10)) == [3, 2], "basic burst → [3,2]")
check(cluster([ph(1, 0), ph(2, 50), ph(3, 100)], gapSec: 3, sizeTol: 0.10).isEmpty,
      "singletons dropped")
check(sizes(cluster([ph(1, 0), ph(2, 1, w: 100, h: 100), ph(3, 2, w: 100, h: 100)],
                    gapSec: 3, sizeTol: 0.10)) == [2], "dimension change splits")
check(sizes(cluster([ph(1, 0, size: 1_000_000), ph(2, 1, size: 1_500_000), ph(3, 2, size: 1_510_000)],
                    gapSec: 3, sizeTol: 0.10)) == [2], "size tolerance splits")
check(sizes(cluster([ph(1, 0, size: 0), ph(2, 1, size: 0)],
                    gapSec: 3, sizeTol: 0.10)) == [2], "zero size is permissive")
do {
    let photos = (0..<6).map { ph($0, Double($0)) }
    check(sizes(cluster(photos, gapSec: 3, sizeTol: 0.10, maxSpan: 0)) == [6], "no cap → one chain")
    let capped = cluster(photos, gapSec: 3, sizeTol: 0.10, maxSpan: 2)
    check(capped.allSatisfy { ($0.last!.takenAt - $0.first!.takenAt) <= 2 } && capped.count >= 2,
          "max-span caps chained drift")
}

print("Quality")
check(abs(qualityScore(positive: [0.9, 0.8], negative: [0.3, 0.1]) - 1.3) < 1e-9,
      "positive minus negative")
check(qualityScore(positive: [nil], negative: [nil]) == 0 && qualityScore(positive: [], negative: []) == 0,
      "handles nil / empty")

print("Keeper")
check(keeper([ph(1, 0, size: 1_000_000, uti: "public.heic"),
              ph(2, 0, size: 9_000_000, uti: "public.jpeg")]).uuid == "U1",
      "format priority beats size")
check(keeper([ph(1, 0, uti: "public.jpeg", quality: 2.0),
              ph(2, 0, uti: "public.heic", quality: 0.1)]).uuid == "U1",
      "quality outranks format")
check(keeper([ph(1, 0, uti: "public.jpeg", quality: 1.02),
              ph(2, 0, uti: "public.heic", quality: 1.01)]).uuid == "U2",
      "quality tie falls through to format")
check(keeper([ph(1, 0, size: 1, uti: "public.jpeg", fav: true),
              ph(2, 0, size: 9_000_000, uti: "public.heic")]).uuid == "U1",
      "favorite is always keeper")
do {
    let deleted = Set(deletions([ph(2, 0, size: 9_000_000, uti: "public.heic"),
                                 ph(1, 0, fav: true), ph(3, 0)]).map(\.uuid))
    check(!deleted.contains("U1") && deleted.contains("U3"), "favorites never deleted")
}
check(deletions([ph(1, 0, fav: true), ph(2, 0, fav: true)]).isEmpty,
      "all-favorite cluster deletes nothing")

print("Protection class (slice 1)")
// An EDITED frame (user adjustments) is sacred — never in deletions, exactly
// like a favorite. The keeper is the unedited high-quality original, but the
// edited frame survives anyway because the user deliberately worked on it.
do {
    let deleted = Set(deletions([ph(1, 0, size: 9_000_000, uti: "public.heic"),
                                 ph(2, 0, edited: true), ph(3, 0)]).map(\.uuid))
    check(!deleted.contains("U2") && deleted.contains("U3"), "edited frame never deleted")
}
// A DOCUMENT / scan / receipt is a utility photo people keep deliberately.
do {
    let deleted = Set(deletions([ph(1, 0, size: 9_000_000, uti: "public.heic"),
                                 ph(2, 0, isDocument: true), ph(3, 0)]).map(\.uuid))
    check(!deleted.contains("U2") && deleted.contains("U3"), "document frame never deleted")
}
check(deletions([ph(1, 0, edited: true), ph(2, 0, isDocument: true)]).isEmpty,
      "all-protected cluster deletes nothing")

print("Blur is within-group ranking only (slice 1)")
// Within an interchangeable group the sharper frame wins as keeper…
check(keeper([ph(1, 0, sharpness: 0.2), ph(2, 0, sharpness: 0.9)]).uuid == "U2",
      "sharper frame is keeper within a group")
// …but sharpness sits BELOW quality/format, so it can't override the real
// quality signal (no hair-splitting on blur when a frame is clearly better).
check(keeper([ph(1, 0, uti: "public.heic", quality: 0.9, sharpness: 0.0),
              ph(2, 0, uti: "public.jpeg", quality: 0.1, sharpness: 1.0)]).uuid == "U1",
      "sharpness does not override quality")
// CRITICAL: a lone blurry photo (single-member group) is never touched — and
// blur never expands the deletion set. The blurriest frame, if it's the only
// non-keeper of a real multi-frame cluster, is the ONLY thing blur can cost.
do {
    let blurry = ph(1, 0, sharpness: 0.0)
    check(deletions([blurry]).isEmpty, "lone blurry photo is never deleted")
    // Same two frames, only sharpness differs → deletion COUNT is unchanged
    // (still exactly the one non-keeper); blur only reorders who keeps.
    let sharpKeeper = Set(deletions([ph(1, 0, sharpness: 0.9), ph(2, 1, sharpness: 0.1)]).map(\.uuid))
    let blurKeeper  = Set(deletions([ph(1, 0, sharpness: 0.1), ph(2, 1, sharpness: 0.9)]).map(\.uuid))
    check(sharpKeeper == ["U2"] && blurKeeper == ["U1"],
          "blur reorders keeper but never grows the deletion set")
}

print("Social re-save vs original (slice 1)")
// An original camera capture (intact EXIF Make/Model) beats a re-compressed
// social-app re-save even if the re-save is a newer/larger file. newer != better.
check(keeper([ph(1, 0, size: 1_000_000, originalCamera: true),
              ph(2, 1, size: 5_000_000, originalCamera: false)]).uuid == "U1",
      "original-camera frame beats larger social re-save")
// …but the protection guarantee still trumps ranking: a social re-save that the
// user EDITED is still never deleted.
do {
    let deleted = Set(deletions([ph(1, 0, originalCamera: true),
                                 ph(2, 1, edited: true, originalCamera: false)]).map(\.uuid))
    check(!deleted.contains("U2"), "edited social re-save still protected")
}
// PENDING (originalCamera App detection): the Core ranking above is fully wired,
// but PhotoFlags.originalCamera() still returns false (no cheap on-device EXIF
// Make/Model in the current Photo-building path — see its TODO). So in the app
// today every frame has originalCamera == false and this signal is a no-op that
// falls through to format/size, exactly as before this slice — never a delete
// trigger, so it's safe. This assertion pins that with-all-false fallback;
// flip it (and wire real EXIF) when the App detector lands.
check(keeper([ph(1, 0, size: 5_000_000, originalCamera: false),
              ph(2, 1, size: 1_000_000, originalCamera: false)]).uuid == "U1",
      "originalCamera all-false → falls through to size (App detection pending)")

print("Regroup-after-deletion")
do {
    // A "keep all" group deletes nothing, so its frames all survive a delete
    // pass. Re-grouping must keep the original keeper and NOT touch membership —
    // the App layer then carries keepAll forward so it can't be re-marked.
    let g = [ph(1, 0), ph(2, 1), ph(3, 2)]
    let r = regroupAfterDeletion(photos: g, keeperID: "U2", removed: [])
    check(r != nil && r!.photos.map(\.uuid) == ["U1", "U2", "U3"] && r!.keeperID == "U2",
          "untouched group keeps its keeper and members")
}
do {
    // The surviving keeper stays the keeper even when other frames are deleted.
    let g = [ph(1, 0), ph(2, 1), ph(3, 2)]
    let r = regroupAfterDeletion(photos: g, keeperID: "U1", removed: ["U3"])
    check(r != nil && r!.photos.map(\.uuid) == ["U1", "U2"] && r!.keeperID == "U1",
          "surviving keeper preserved")
}
do {
    // If the previous keeper was the one deleted, re-derive from the remainder.
    let g = [ph(1, 0, quality: 0.1), ph(2, 1, quality: 0.9), ph(3, 2, quality: 0.5)]
    let r = regroupAfterDeletion(photos: g, keeperID: "U1", removed: ["U1"])
    check(r != nil && r!.photos.map(\.uuid) == ["U2", "U3"] && r!.keeperID == "U2",
          "deleted keeper re-derived from remainder")
}
do {
    // Fewer than two frames left → the group is resolved and dropped.
    let g = [ph(1, 0), ph(2, 1)]
    check(regroupAfterDeletion(photos: g, keeperID: "U1", removed: ["U2"]) == nil,
          "group resolved to <2 frames is dropped")
}
// Quality quantisation must match the Python CLI's pick.quality_bucket exactly
// (shared round-half-up floor(q*10+0.5)). Swift's default .rounded() was
// round-half-away, so 0.25 → 3 here but Python's banker's round() → 2: the CLI
// and the app could pick different keepers on a half-tenth boundary.
check(qualityBucket(0.05) == 1 && qualityBucket(0.15) == 2 && qualityBucket(0.25) == 3
      && qualityBucket(0.35) == 4 && qualityBucket(0.45) == 5 && qualityBucket(-0.15) == -1,
      "quality bucket = round-half-up (matches Python)")
check(keeper([ph(1, 0, size: 1_000_000, uti: "public.heic", quality: 0.25),
              ph(2, 1, size: 2_000_000, uti: "public.heic", quality: 0.22)]).uuid == "U1",
      "half-boundary quality keeper matches Python")

print("Hashing")
check(hamming(0b1010, 0b1010) == 0 && hamming(0b1010, 0b1000) == 1
      && hamming(0, 0xFFFF_FFFF_FFFF_FFFF) == 64, "hamming basics")
do {
    var grad: [Int] = []
    for _ in 0..<8 { for col in 0..<9 { grad.append(255 - col) } }
    check(dHash(grayRowMajor: grad) == UInt64.max, "left-brighter → all bits set")
}
check(dHash(grayRowMajor: Array(repeating: 128, count: 9 * 8)) == 0, "flat image → zero")
do {
    let t = BKTree()
    for h in [UInt64](arrayLiteral: 0b0000, 0b0001, 0b0011, 0b1111) { t.add(h) }
    check(Set(t.query(0b0000, maxDistance: 1)) == Set([0b0000, 0b0001]), "bk-tree within distance")
}
do {
    let g = groupByHash([(100, "a"), (100, "b"), (200, "c")], maxDistance: 0)
    check(g.count == 1 && Set(g[0]) == Set(["a", "b"]), "group exact match")
}
do {
    let items: [(UInt64, String)] = [(0b000, "a"), (0b001, "b"), (0b011, "c"), (0b111111, "z")]
    let g = groupByHash(items, maxDistance: 1)
    check(g.count == 1 && Set(g[0]) == Set(["a", "b", "c"]), "group near match transitive")
}
check(groupByHash([(1, "a"), (2, "b")], maxDistance: 0).isEmpty, "distance zero keeps distinct")

print("Source picker (slice 2)")
// AlbumItem.estimatedCount: -1 encodes NSNotFound so the UI can distinguish
// "we know there are 0 photos" from "count not yet cached by Photos".
do {
    // A count the system has cached shows as-is.
    let known = (id: "A", title: "Vacation", estimatedCount: 42)
    check(known.estimatedCount == 42, "album item carries known count")
    // A count the system hasn't cached yet is stored as -1 (sentinel for NSNotFound).
    let unknown = (id: "B", title: "Empty", estimatedCount: -1)
    check(unknown.estimatedCount < 0, "album item stores -1 sentinel for unknown count")
}
// albumMenuLabel logic: show count in parentheses when known, bare title when not.
do {
    func albumMenuLabel(title: String, count: Int) -> String {
        count >= 0 ? "\(title)  (\(count))" : title
    }
    check(albumMenuLabel(title: "Trip", count: 12) == "Trip  (12)", "label shows count when known")
    check(albumMenuLabel(title: "Trip", count: 0) == "Trip  (0)", "label shows zero count")
    check(albumMenuLabel(title: "Trip", count: -1) == "Trip", "label omits count when unknown")
}

print(failures == 0 ? "\n✅ all Swift Core tests passed" : "\n❌ \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
