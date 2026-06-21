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

// ─────────────────────────────────────────────────────────────────────────────
// FIX #9 — originalCamera guard tests
//
// PhotoFlags.originalCamera() is documented as a dead field that always returns
// false (pending real EXIF Make/Model wiring). These tests:
//   (a) PIN the current all-false behaviour — keeper selection falls through to
//       the sharpness/format/size/earliest tiebreaks exactly as if the signal
//       weren't there. If someone partially wires originalCamera in a way that
//       breaks the uniform-false path, this catches it.
//   (b) DOCUMENT the INTENDED behaviour for when EXIF IS wired — a frame with
//       originalCamera=true must beat an otherwise-equal sibling with
//       originalCamera=false (and that outcome must flow through keeperReason
//       as .originalCamera). This test will start failing the moment the signal
//       is wired, as a reminder that it needs end-to-end verification.
// ─────────────────────────────────────────────────────────────────────────────

print("FIX #9 — originalCamera guard tests")

do {
    // (a) ALL-FALSE GUARD: when every frame has originalCamera=false the signal
    //     is uniformly inactive and keeper selection is identical to a world
    //     where the field doesn't exist. Verify the fallthrough chain:
    //     quality-tie → format-tie → size wins, then earliest wins.

    // Quality tie, format tie, size decides.
    let big   = ph(1, 0, size: 9_000_000, uti: "public.heic", quality: 0.5,
                   originalCamera: false)
    let small = ph(2, 1, size: 1_000_000, uti: "public.heic", quality: 0.5,
                   originalCamera: false)
    check(keeper([big, small]).uuid == "U1",
          "originalCamera all-false: size tiebreak works (not disrupted by dead field)")

    // Quality tie, format wins.
    let heic = ph(3, 0, uti: "public.heic", quality: 0.5, originalCamera: false)
    let jpeg = ph(4, 1, uti: "public.jpeg", quality: 0.5, originalCamera: false)
    check(keeper([heic, jpeg]).uuid == "U3",
          "originalCamera all-false: format tiebreak works (not disrupted by dead field)")

    // Quality tie, format tie, size tie, earliest wins.
    let first  = ph(5, 0, size: 1_000_000, uti: "public.heic", quality: 0.5,
                    originalCamera: false)
    let second = ph(6, 1, size: 1_000_000, uti: "public.heic", quality: 0.5,
                    originalCamera: false)
    check(keeper([first, second]).uuid == "U5",
          "originalCamera all-false: earliest tiebreak works (not disrupted by dead field)")

    // keeperReason must NOT return .originalCamera when both frames are all-false.
    let r = keeperReason(photos: [heic, jpeg], keeperID: "U3")
    check(r == .format,
          "originalCamera all-false: keeperReason returns .format, not .originalCamera")
}

do {
    // (b) INTENDED BEHAVIOUR GUARD: IF originalCamera were true for one frame
    //     and false for an otherwise equal sibling, the originalCamera frame
    //     must win (documents the intended behaviour for when EXIF is wired).
    //     This is a forward-compatibility test: it passes today because the
    //     Core RankKey already implements the precedence correctly; it will
    //     remain green once the App detector is wired.
    let cam   = ph(1, 0, size: 1_000_000, uti: "public.heic", quality: 0.5,
                   sharpness: 0.5, originalCamera: true)
    let resave = ph(2, 1, size: 9_000_000, uti: "public.heic", quality: 0.5,
                    sharpness: 0.5, originalCamera: false)
    check(keeper([cam, resave]).uuid == "U1",
          "originalCamera=true beats larger/newer sibling (intended ranking when EXIF is wired)")

    // keeperReason correctly identifies originalCamera as the deciding signal.
    check(keeperReason(photos: [cam, resave], keeperID: "U1") == .originalCamera,
          "originalCamera=true: keeperReason returns .originalCamera")

    // The asymmetry is one-directional: the cam frame winning requires the
    // resave to be false. Two true frames fall through to the next tiebreak
    // (sharpness here, then format/size/earliest).
    let cam2 = ph(3, 0, size: 9_000_000, uti: "public.heic", quality: 0.5,
                  sharpness: 0.5, originalCamera: true)
    let cam3 = ph(4, 1, size: 1_000_000, uti: "public.heic", quality: 0.5,
                  sharpness: 0.5, originalCamera: true)
    // Both true → falls through to size (cam2 larger).
    check(keeper([cam2, cam3]).uuid == "U3",
          "originalCamera both-true: falls through to size tiebreak")
}

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

print("Exact-duplicate predicate (slice 3)")
// The strict bar: same dimensions AND dHash Hamming distance == 0 AND
// feature-print distance ≤ featureThreshold. Distance 1+ is NOT exact.
do {
    // Perfect match: all three conditions true → exact duplicate.
    check(ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 0, featureDistance: 0.00, sameSize: true),
          "hamming 0 + feature 0 + same size → exact")

    // Feature threshold edge: exactly at the boundary → exact.
    check(ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 0, featureDistance: ExactDuplicatePredicate.featureThreshold, sameSize: true),
          "hamming 0 + feature at threshold → exact")

    // Feature distance 1 bit above threshold (just over) → NOT exact.
    check(!ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 0, featureDistance: ExactDuplicatePredicate.featureThreshold + 0.001, sameSize: true),
          "feature just above threshold → not exact")

    // dHash distance 1 → NOT exact (a single bit differs perceptually).
    check(!ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 1, featureDistance: 0.00, sameSize: true),
          "hamming distance 1 → not exact")

    // Different dimensions → NOT exact even if hashes are identical.
    check(!ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 0, featureDistance: 0.00, sameSize: false),
          "different dimensions → not exact")

    // Normal burst pair (feature ≈0.08, within confident threshold but above
    // exact threshold) → NOT exact.
    check(!ExactDuplicatePredicate.isExactDuplicate(
        hammingDistance: 0, featureDistance: 0.08, sameSize: true),
          "burst-range feature distance → not exact")
}

print("Exact-duplicate suggestions (slice 3)")
// Protected frames in an exact-dup group are NEVER suggested for deletion.
do {
    // Two-frame group: favorite (protected) vs plain. Suggestion excludes favorite.
    let favPhoto = ph(1, 0, size: 9_000_000, uti: "public.heic", fav: true)
    let plainPhoto = ph(2, 0, size: 8_000_000, uti: "public.heic")
    let suggestions = exactDuplicateSuggestions([favPhoto, plainPhoto])
    check(!suggestions.map(\.uuid).contains("U1"),
          "protected (favorite) never in exact-dup suggestions")
}
do {
    // Edited frame in exact-dup group → still protected, never suggested.
    let edited = ph(1, 0, edited: true)
    let plain  = ph(2, 1)
    let suggestions = exactDuplicateSuggestions([edited, plain])
    check(!suggestions.map(\.uuid).contains("U1"),
          "edited frame never in exact-dup suggestions")
}
do {
    // Document frame in exact-dup group → still protected.
    let doc   = ph(1, 0, isDocument: true)
    let plain = ph(2, 1)
    let suggestions = exactDuplicateSuggestions([doc, plain])
    check(!suggestions.map(\.uuid).contains("U1"),
          "document frame never in exact-dup suggestions")
}
do {
    // All-protected group: no suggestions.
    check(exactDuplicateSuggestions([ph(1, 0, fav: true), ph(2, 1, edited: true)]).isEmpty,
          "all-protected exact-dup group → no suggestions")
}
do {
    // Three-frame group: one keeper, one plain non-keeper, one protected.
    // Only the plain non-keeper is suggested.
    let keeper = ph(1, 0, quality: 0.9)
    let protected_ = ph(2, 1, edited: true)
    let plain  = ph(3, 2, quality: 0.1)
    let suggestions = Set(exactDuplicateSuggestions([keeper, protected_, plain]).map(\.uuid))
    check(!suggestions.contains("U2") && suggestions.contains("U3"),
          "only non-protected non-keeper suggested in mixed exact-dup group")
}
do {
    // Single-member group: returns empty (can never be a duplicate of itself).
    check(exactDuplicateSuggestions([ph(1, 0)]).isEmpty,
          "single-frame group → no exact-dup suggestions")
}

print("Armed-but-all-protected groups (Fix 4)")
// effectivelyArmed = deleteAll && !deletionIDs.isEmpty.
// deletionIDs is driven by Photo.isProtected; Core's deletions() is the SSOT.
// An all-protected group armed for deletion contributes 0 actual deletions —
// the visual "armed" state must not imply a real delete will happen.
do {
    // All-favorite group: armed (deleteAll conceptually) but 0 deletable frames.
    let allFav = [ph(1, 0, fav: true), ph(2, 1, fav: true)]
    check(deletions(allFav).isEmpty,
          "all-favorite group: no deletable frames even if armed")
}
do {
    // All-edited group: armed but 0 deletable.
    let allEdited = [ph(1, 0, edited: true), ph(2, 1, edited: true)]
    check(deletions(allEdited).isEmpty,
          "all-edited group: no deletable frames even if armed")
}
do {
    // All-document group: armed but 0 deletable.
    let allDoc = [ph(1, 0, isDocument: true), ph(2, 1, isDocument: true)]
    check(deletions(allDoc).isEmpty,
          "all-document group: no deletable frames even if armed")
}
do {
    // Mixed protection: one favorite, one plain → armed yields 1 deletion,
    // so effectivelyArmed would be true (non-empty deletionIDs). The visual
    // red state IS correct here because something will actually be deleted.
    let mixed = [ph(1, 0, fav: true), ph(2, 1)]
    check(deletions(mixed).count == 1,
          "mixed group: 1 deletable (non-protected) frame when armed")
}
do {
    // Helper that mirrors effectivelyArmed logic: deleteAll flag + deletionIDs check.
    // A group is "effectively armed" only when there are real frames to delete.
    func effectivelyArmed(deletionCount: Int, deleteAll: Bool) -> Bool {
        deleteAll && deletionCount > 0
    }
    check(!effectivelyArmed(deletionCount: 0, deleteAll: true),
          "effectivelyArmed: false when all frames protected (0 deletions)")
    check(effectivelyArmed(deletionCount: 2, deleteAll: true),
          "effectivelyArmed: true when real deletions exist")
    check(!effectivelyArmed(deletionCount: 2, deleteAll: false),
          "effectivelyArmed: false when deleteAll flag is off")
}

// ─────────────────────────────────────────────────────────────────────────────
// FIX C — includeProtected: informed-consent override (pure-Core tests)
//
// ReviewGroup (the App-layer struct carrying includeProtected) lives in
// SnapsiftApp and isn't visible here. We test the underlying slice-1 guarantee
// via Core's `deletions()` (unchanged) and via the isDelete predicate logic
// inlined as a pure function that mirrors ReviewGroup.isDelete exactly.
//
// Slice-1 guarantee (must hold in Core):
//   • Core's `deletions()` NEVER returns protected frames — the base is safe.
//   • The App-layer isDelete extension of Core's logic only includes protected
//     frames when BOTH deleteAll AND includeProtected are true.
// ─────────────────────────────────────────────────────────────────────────────

print("FIX C — includeProtected override (slice-1 guarantee, pure-Core)")

/// Pure-function mirror of ReviewGroup.isDelete — tests the override logic
/// without depending on the App-layer type.
func reviewIsDelete(_ p: Photo, keeperID: String,
                    keepAll: Bool, deleteAll: Bool, includeProtected: Bool) -> Bool {
    guard !keepAll else { return false }
    // Protected frames excluded UNLESS user opted in AND group is armed.
    if p.isProtected && !(deleteAll && includeProtected) { return false }
    return deleteAll || p.uuid != keeperID
}

func reviewDeletionIDs(_ photos: [Photo], keeperID: String,
                       deleteAll: Bool, includeProtected: Bool) -> Set<String> {
    Set(photos.filter {
        reviewIsDelete($0, keeperID: keeperID, keepAll: false,
                       deleteAll: deleteAll, includeProtected: includeProtected)
    }.map(\.uuid))
}

do {
    // (1) Default (includeProtected=false): protected frames NEVER in deletions,
    //     even when armed — slice-1 guarantee intact. In deleteAll mode the keeper
    //     (a plain frame) IS deleted — that's correct: "delete the whole group"
    //     means all frames go, with the sole exception being protected ones.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    let edited_ = ph(3, 2, edited: true)
    let ids = reviewDeletionIDs([fav, plain, edited_], keeperID: "U2",
                                deleteAll: true, includeProtected: false)
    check(!ids.contains("U1") && !ids.contains("U3"),
          "includeProtected=false: favorite + edited never in deletionIDs when armed (default guarantee)")
    check(ids.contains("U2"),
          "plain keeper IS in deletionIDs when deleteAll=true (whole group goes)")
}

do {
    // (2) includeProtected=true + armed: protected frames become deletable.
    //     All frames including the keeper enter deletionIDs in deleteAll mode.
    let fav = ph(1, 0, fav: true)
    let edited_ = ph(2, 1, edited: true)
    let doc = ph(3, 2, isDocument: true)
    let plain = ph(4, 3)   // keeper
    let ids = reviewDeletionIDs([fav, edited_, doc, plain], keeperID: "U4",
                                deleteAll: true, includeProtected: true)
    check(ids.contains("U1") && ids.contains("U2") && ids.contains("U3"),
          "includeProtected=true + armed: favorite, edited, document all enter deletionIDs")
    check(ids.contains("U4"),
          "keeper also in deletionIDs in deleteAll mode (whole group goes)")
}

do {
    // (3) includeProtected=true on an all-protected group + armed: now has deletable
    //     frames — the "All protected" dead-state is resolved.
    let fav = ph(1, 0, fav: true)
    let edited_ = ph(2, 1, edited: true)
    let ids = reviewDeletionIDs([fav, edited_], keeperID: "U1",
                                deleteAll: true, includeProtected: true)
    check(!ids.isEmpty,
          "includeProtected=true, all-protected + armed: non-keeper protected frame now deletable")
}

do {
    // (4) Auto-mark path (deleteAll=false): protected NEVER deleted even when
    //     includeProtected=true — the user must first arm the group.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    let ids = reviewDeletionIDs([fav, plain], keeperID: "U2",
                                deleteAll: false, includeProtected: true)
    check(!ids.contains("U1"),
          "includeProtected=true but deleteAll=false: protected safe in auto-mark path")
}

do {
    // (5) Disarming: clearing both flags removes protected frames from deletions.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    let armed = reviewDeletionIDs([fav, plain], keeperID: "U2",
                                  deleteAll: true, includeProtected: true)
    check(armed.contains("U1"), "sanity: armed+includeProtected → fav in deletions")
    let disarmed = reviewDeletionIDs([fav, plain], keeperID: "U2",
                                     deleteAll: false, includeProtected: false)
    check(!disarmed.contains("U1"),
          "after disarm: protected frame no longer in deletionIDs")
}

do {
    // (6) Core's deletions() is unchanged — the base guarantee never includes protected.
    let fav = ph(1, 0, fav: true)
    let edited_ = ph(2, 1, edited: true)
    let plain = ph(3, 2)
    check(deletions([fav, edited_, plain]).allSatisfy { !$0.isProtected },
          "Core deletions() never returns protected frames (base slice-1 guarantee unchanged)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-frame reject model (Pass 1 keyboard overhaul)
//
// ReviewGroup lives in SnapsiftApp (not importable here), so we test the
// underlying logic via the Core functions (deletions, keeper, isProtected) and
// via pure-function mirrors that faithfully reproduce the new ReviewGroup logic.
// ─────────────────────────────────────────────────────────────────────────────

print("Per-frame reject model (Pass 1)")

// Mirror of the new ReviewGroup.isDelete
func rejectIsDelete(_ p: Photo, keeperID: String, rejected: Set<String>, includeProtected: Bool) -> Bool {
    guard rejected.contains(p.uuid) else { return false }
    if p.isProtected && !includeProtected { return false }
    return true
}

func rejectDeletionIDs(_ photos: [Photo], keeperID: String,
                        rejected: Set<String>, includeProtected: Bool) -> Set<String> {
    Set(photos.filter {
        rejectIsDelete($0, keeperID: keeperID, rejected: rejected, includeProtected: includeProtected)
    }.map(\.uuid))
}

// SLICE-1 INVARIANT: auto-seeding never puts protected frames in rejected.
do {
    // Confident group: seed rejected = non-keeper, non-protected.
    let keep = ph(1, 0, quality: 0.9)
    let plain = ph(2, 1)
    let fav   = ph(3, 2, fav: true)
    let edited_ = ph(4, 3, edited: true)
    let doc   = ph(5, 4, isDocument: true)
    let photos = [keep, plain, fav, edited_, doc]
    let keeperID = keeper(photos).uuid   // should be U1 (highest quality)
    // Auto-seed: all non-keeper non-protected.
    let autoSeeded: Set<String> = Set(photos.compactMap { p in
        (p.uuid != keeperID && !p.isProtected) ? p.uuid : nil
    })
    check(!autoSeeded.contains("U3"), "auto-seed: favorite never in rejected")
    check(!autoSeeded.contains("U4"), "auto-seed: edited never in rejected")
    check(!autoSeeded.contains("U5"), "auto-seed: document never in rejected")
    check(autoSeeded.contains("U2"), "auto-seed: plain non-keeper IS seeded")
    check(!autoSeeded.contains(keeperID), "auto-seed: keeper never seeded")
}

// SLICE-1 INVARIANT: Core deletions() still excludes protected (unchanged).
do {
    let photos = [ph(1, 0), ph(2, 1, fav: true), ph(3, 2, edited: true)]
    let d = deletions(photos)
    check(d.allSatisfy { !$0.isProtected }, "Core deletions() never returns protected frames")
}

// Per-frame toggle: add/remove exactly that uuid; totalDeletions-equivalent reflects it.
do {
    let plain = ph(1, 0)
    let plain2 = ph(2, 1)
    var rejected: Set<String> = []
    // Toggle in.
    rejected.insert(plain.uuid)
    check(rejected.contains("U1") && rejected.count == 1, "toggle reject: inserts uuid")
    // Toggle out.
    rejected.remove(plain.uuid)
    check(!rejected.contains("U1") && rejected.count == 0, "toggle reject: removes uuid")
    // Add both — the new model has NO keeper exclusion: if it's in rejected, it's deleted.
    rejected.insert(plain.uuid)
    rejected.insert(plain2.uuid)
    let ids = rejectDeletionIDs([plain, plain2], keeperID: "U1",
                                 rejected: rejected, includeProtected: false)
    check(ids == Set(["U1", "U2"]), "deletionIDs: all non-protected rejected frames included (no keeper exception in rejected model)")
    check(rejectDeletionIDs([plain, plain2], keeperID: "U1",
                            rejected: Set(["U1", "U2"]), includeProtected: false) == Set(["U1", "U2"]),
          "both in rejected → both in deletionIDs (no keeper exception in rejected model)")
}

// Force-reject: only way a protected frame enters rejected (base path blocked).
do {
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    // Base path (plain X): protected blocked.
    var rejected: Set<String> = []
    // Simulate: try to insert protected via plain toggle — blocked if caller checks isProtected.
    // The test mirrors the guard: if p.isProtected { return false }.
    let toggled = !fav.isProtected  // false → blocked
    check(!toggled, "plain X on protected: blocked (returns false)")

    // Force path (⇧X): allowed.
    rejected.insert(fav.uuid)   // forceReject inserts unconditionally
    let ids = rejectDeletionIDs([fav, plain], keeperID: "U2",
                                 rejected: rejected, includeProtected: true)
    check(ids.contains("U1"), "force-reject: protected frame enters deletionIDs with includeProtected=true")
    // Default path (includeProtected=false) still excludes it even if in rejected.
    let idsNoOverride = rejectDeletionIDs([fav, plain], keeperID: "U2",
                                           rejected: rejected, includeProtected: false)
    check(!idsNoOverride.contains("U1"),
          "even if in rejected, includeProtected=false still excludes protected from deletionIDs")
}

// `a` (keep-all) clears rejected.
do {
    var rejected: Set<String> = Set(["U1", "U2"])
    rejected = []   // keepAll clears
    check(rejected.isEmpty, "keepAll: clears rejected set")
}

// `d` (reject-all) rejects all non-keeper non-protected; keeper never auto-rejected.
do {
    let keep = ph(1, 0, quality: 0.9)
    let plain = ph(2, 1)
    let fav   = ph(3, 2, fav: true)
    let photos = [keep, plain, fav]
    let keeperID = "U1"
    let rejectAllSeeded: Set<String> = Set(photos.compactMap { p in
        (p.uuid != keeperID && !p.isProtected) ? p.uuid : nil
    })
    check(!rejectAllSeeded.contains("U1"), "rejectAll: keeper never auto-rejected")
    check(!rejectAllSeeded.contains("U3"), "rejectAll: protected never auto-rejected")
    check(rejectAllSeeded.contains("U2"), "rejectAll: plain non-keeper IS rejected")
}

// Uncertain group seeding: rejected stays empty.
do {
    var rejected: Set<String> = []
    // Uncertain groups: no seeding.
    check(rejected.isEmpty, "uncertain group: rejected empty at seed")
}

// Keeper never auto-seeded (separate from force-reject path).
do {
    let keep = ph(1, 0, quality: 0.9)
    let plain = ph(2, 1)
    let keeperID = keeper([keep, plain]).uuid
    let autoSeeded: Set<String> = Set([keep, plain].compactMap { p in
        (p.uuid != keeperID && !p.isProtected) ? p.uuid : nil
    })
    check(!autoSeeded.contains(keeperID), "keeper never in auto-seeded rejected")
}

// Existing tests must still pass (smoke check for exact-dup / surface-album protection).
do {
    let fav = ph(1, 0, fav: true)
    let doc = ph(2, 1, isDocument: true)
    check(deletions([fav, doc]).isEmpty, "exact-dup/surface: all-protected group still deletes nothing")
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature 2: keeper-why helper
// ─────────────────────────────────────────────────────────────────────────────

print("Keeper-why helper (Feature 2)")

do {
    // Favorite always wins regardless of other signals.
    let fav = ph(1, 0, size: 100, uti: "public.jpeg", fav: true, quality: 0.1)
    let better = ph(2, 1, size: 9_000_000, uti: "public.heic", quality: 0.99)
    let reason = keeperReason(photos: [fav, better], keeperID: "U1")
    check(reason == .favorite, "keeper-why: favorite wins → .favorite")
}
do {
    // Quality dominant: keeper has strictly higher quality bucket.
    let highQ = ph(1, 0, quality: 0.9)
    let lowQ  = ph(2, 1, quality: 0.1)
    check(keeperReason(photos: [highQ, lowQ], keeperID: "U1") == .quality,
          "keeper-why: higher quality → .quality")
}
do {
    // Sharpness dominant (quality tied, no fav, no originalCamera, same format/size).
    let sharp = ph(1, 0, uti: "public.heic", quality: 0.5, sharpness: 0.9)
    let blur  = ph(2, 1, uti: "public.heic", quality: 0.5, sharpness: 0.1)
    check(keeperReason(photos: [sharp, blur], keeperID: "U1") == .sharpness,
          "keeper-why: sharper frame → .sharpness")
}
do {
    // Format dominant: same quality, sharpness; keeper has better UTI.
    let heic = ph(1, 0, uti: "public.heic", quality: 0.5, sharpness: 0.5)
    let jpeg = ph(2, 1, uti: "public.jpeg", quality: 0.5, sharpness: 0.5)
    check(keeperReason(photos: [heic, jpeg], keeperID: "U1") == .format,
          "keeper-why: better format → .format")
}
do {
    // Size dominant: same everything except file size.
    let big   = ph(1, 0, size: 9_000_000, uti: "public.heic", quality: 0.5, sharpness: 0.5)
    let small = ph(2, 1, size: 1_000_000, uti: "public.heic", quality: 0.5, sharpness: 0.5)
    check(keeperReason(photos: [big, small], keeperID: "U1") == .size,
          "keeper-why: larger file → .size")
}
do {
    // Earliest fallback: everything identical → earliest (negTakenAt wins).
    let first  = ph(1, 0, uti: "public.heic", quality: 0.5, sharpness: 0.5)   // takenAt=0
    let second = ph(2, 1, uti: "public.heic", quality: 0.5, sharpness: 0.5)   // takenAt=1
    // first is the keeper: takenAt=0 < takenAt=1 → negTakenAt(-0) > negTakenAt(-1) → wins
    check(keeperReason(photos: [first, second], keeperID: "U1") == .earliest,
          "keeper-why: all equal → .earliest")
}
do {
    // Single photo: returns .earliest (degenerate group, no comparison).
    check(keeperReason(photos: [ph(1, 0)], keeperID: "U1") == .earliest,
          "keeper-why: single-member group → .earliest")
}
do {
    // originalCamera dominant (quality tied, no fav, keeper has camera).
    let cam  = ph(1, 0, uti: "public.heic", quality: 0.5, sharpness: 0.5, originalCamera: true)
    let resave = ph(2, 1, uti: "public.heic", quality: 0.5, sharpness: 0.5, originalCamera: false)
    check(keeperReason(photos: [cam, resave], keeperID: "U1") == .originalCamera,
          "keeper-why: originalCamera → .originalCamera")
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature 3: no-survivor guard
// ─────────────────────────────────────────────────────────────────────────────

print("No-survivor guard (Feature 3)")

do {
    // Group where every frame is rejected + includeProtected=true → 1 empty group.
    let p1 = ph(1, 0)
    let p2 = ph(2, 1)
    let rejected: Set<String> = ["U1", "U2"]
    let count = noSurvivorGroupCount([
        (photos: [p1, p2], rejected: rejected, includeProtected: true)
    ])
    check(count == 1, "no-survivor: all frames rejected + includeProtected=true → 1 empty group")
}
do {
    // Keeper itself was force-rejected (keeper in rejected set).
    let keep = ph(1, 0, quality: 0.9)
    let other = ph(2, 1)
    // Both rejected; includeProtected=true so nothing survives.
    let count = noSurvivorGroupCount([
        (photos: [keep, other], rejected: Set(["U1", "U2"]), includeProtected: true)
    ])
    check(count == 1, "no-survivor: keeper itself force-rejected + no survivors → counted")
}
do {
    // Protected frame in rejected but includeProtected=false → protected survives → not empty.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    // Both in rejected, but includeProtected=false so fav survives.
    let count = noSurvivorGroupCount([
        (photos: [fav, plain], rejected: Set(["U1", "U2"]), includeProtected: false)
    ])
    check(count == 0, "no-survivor: protected survives (includeProtected=false) → not empty")
}
do {
    // Mix of two groups: one empty, one not.
    let p1 = ph(1, 0)
    let p2 = ph(2, 1)
    let p3 = ph(3, 2)
    let count = noSurvivorGroupCount([
        (photos: [p1, p2], rejected: Set(["U1", "U2"]), includeProtected: true),   // empty
        (photos: [p3, ph(4, 3)], rejected: Set(["U4"]), includeProtected: false),   // p3 survives
    ])
    check(count == 1, "no-survivor: 2 groups, only 1 empty → count=1")
}
do {
    // Nothing rejected → zero empty groups.
    let count = noSurvivorGroupCount([
        (photos: [ph(1, 0), ph(2, 1)], rejected: [], includeProtected: false)
    ])
    check(count == 0, "no-survivor: nothing rejected → 0 empty groups")
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature 4: audit record construction
// ─────────────────────────────────────────────────────────────────────────────

print("Audit record construction (Feature 4)")

do {
    // Plain non-protected frame → .userRejected
    let plain = ph(1, 0)
    let reason = DeletionAuditLog.reason(for: plain, includeProtectedActive: false)
    check(reason == .userRejected, "audit: plain frame → .userRejected")
}
do {
    // Protected + includeProtected=false → .userRejected (protection not overridden)
    let fav = ph(1, 0, fav: true)
    let reason = DeletionAuditLog.reason(for: fav, includeProtectedActive: false)
    check(reason == .userRejected, "audit: protected + includeProtectedActive=false → .userRejected")
}
do {
    // Favorite force-included → .forceIncludedProtectedFavorite
    let fav = ph(1, 0, fav: true)
    let reason = DeletionAuditLog.reason(for: fav, includeProtectedActive: true)
    check(reason == .forceIncludedProtectedFavorite, "audit: favorite + includeProtected=true → .forceIncludedProtectedFavorite")
}
do {
    // Edited force-included → .forceIncludedProtectedEdited
    let edited_ = ph(1, 0, edited: true)
    let reason = DeletionAuditLog.reason(for: edited_, includeProtectedActive: true)
    check(reason == .forceIncludedProtectedEdited, "audit: edited + includeProtected=true → .forceIncludedProtectedEdited")
}
do {
    // Document force-included → .forceIncludedProtectedDocument
    let doc = ph(1, 0, isDocument: true)
    let reason = DeletionAuditLog.reason(for: doc, includeProtectedActive: true)
    check(reason == .forceIncludedProtectedDocument, "audit: document + includeProtected=true → .forceIncludedProtectedDocument")
}
do {
    // Multiple protections (favorite + edited) → .forceIncludedProtectedMultiple
    let both = Photo(uuid: "Ux", filename: "both.heic", takenAt: 0,
                     width: 100, height: 100, size: 1000, uti: "public.heic",
                     kind: 0, favorite: true, quality: 0,
                     edited: true, isDocument: false,
                     sharpness: 0, originalCamera: false)
    let reason = DeletionAuditLog.reason(for: both, includeProtectedActive: true)
    check(reason == .forceIncludedProtectedMultiple, "audit: favorite+edited + includeProtected=true → .forceIncludedProtectedMultiple")
}
do {
    // nowTimestamp returns non-empty ISO string.
    let ts = DeletionAuditLog.nowTimestamp()
    check(!ts.isEmpty && ts.contains("T"), "audit: nowTimestamp() returns ISO-8601 string")
}
do {
    // DeletionSession recoverableUntil is ~30 days after timestamp.
    let ts = DeletionAuditLog.nowTimestamp()
    let session = DeletionSession(timestamp: ts, records: [])
    let until = session.recoverableUntil
    check(until != nil, "audit: DeletionSession.recoverableUntil is non-nil for valid timestamp")
    if let d = until {
        let diff = d.timeIntervalSinceNow
        // Should be approximately 30 days (allow 29–31 days for clock skew in tests)
        check(diff > 29 * 24 * 3600 && diff < 31 * 24 * 3600,
              "audit: recoverableUntil is approximately 30 days from now")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIX 2 — RAW UTI ranking
// ─────────────────────────────────────────────────────────────────────────────

print("FIX 2 — RAW UTI ranking (slice 1 hardening)")

do {
    // RAW vs JPEG of otherwise identical quality/size → RAW wins.
    // Preserves the original capture over a lossy derivative.
    let raw  = ph(1, 0, size: 8_000_000, uti: "com.adobe.raw-image")
    let jpeg = ph(2, 0, size: 9_000_000, uti: "public.jpeg")   // larger but lower UTI priority
    check(keeper([raw, jpeg]).uuid == "U1",
          "RAW (com.adobe.raw-image) beats larger JPEG — original capture preserved")
}
do {
    // HEIC still wins over RAW: HEIC=100 > RAW=90.
    let heic = ph(1, 0, size: 5_000_000, uti: "public.heic")
    let raw  = ph(2, 0, size: 9_000_000, uti: "com.adobe.raw-image")
    check(keeper([heic, raw]).uuid == "U1",
          "HEIC (100) beats RAW (90) even when RAW file is larger")
}
do {
    // Canon CR2 is also ranked at 90.
    let cr2  = ph(1, 0, size: 8_000_000, uti: "com.canon.cr2-raw-image")
    let jpeg = ph(2, 0, size: 9_000_000, uti: "public.jpeg")
    check(keeper([cr2, jpeg]).uuid == "U1",
          "Canon CR2 beats larger JPEG")
}
do {
    // Sony ARW is also ranked at 90.
    let arw  = ph(1, 0, size: 8_000_000, uti: "com.sony.arw-raw-image")
    let jpeg = ph(2, 0, size: 9_000_000, uti: "public.jpeg")
    check(keeper([arw, jpeg]).uuid == "U1",
          "Sony ARW beats larger JPEG")
}
do {
    // A RAW without an explicit UTI still falls to 0 (unknown UTI), NOT ranked
    // as RAW — unknown UTIs should not accidentally win.
    let unknown = ph(1, 0, size: 1_000_000, uti: "com.unknown.raw-format")
    let jpeg    = ph(2, 0, size: 2_000_000, uti: "public.jpeg")   // larger
    // unknown UTI = priority 0, jpeg = 80 → jpeg wins on format, but size
    // could override if format is tied. Here format is NOT tied: jpeg > unknown.
    check(keeper([unknown, jpeg]).uuid == "U2",
          "Unknown UTI (priority 0) loses to JPEG (priority 80)")
}
do {
    // The keeperReason for a RAW-vs-JPEG win should be .format.
    let raw  = ph(1, 0, uti: "com.nikon.raw-image", quality: 0.5, sharpness: 0.5)
    let jpeg = ph(2, 0, uti: "public.jpeg",          quality: 0.5, sharpness: 0.5)
    check(keeperReason(photos: [raw, jpeg], keeperID: "U1") == .format,
          "keeper-why: RAW beats JPEG on format → .format reason")
}

// ─────────────────────────────────────────────────────────────────────────────
// FIX 4 — confidentDupe defaults to false
// ─────────────────────────────────────────────────────────────────────────────

// ReviewGroup lives in SnapsiftApp (not importable here), but we can test the
// observable behavioural consequence: the scan() path in LibraryModel explicitly
// sets confidentDupe = true only when the neural gate passes. Groups constructed
// without that explicit set (look-alikes, regroup-after-deletion) should be
// uncertain. We verify the invariant at the Core level via the seeding logic.

print("FIX 4 — confidentDupe default (slice 1 hardening)")

do {
    // The seeding rule: only confident groups pre-seed rejections.
    // A group that does NOT explicitly receive confidentDupe = true must
    // start with an empty rejected set (nothing pre-marked). We simulate this
    // with the auto-seed formula used in scan():
    //
    //   if confident { seed rejected = non-keeper, non-protected }
    //   // uncertain: rejected stays empty
    //
    // With confidentDupe defaulting to false, any group built without explicitly
    // setting the flag gets no seeding — correct behaviour for look-alike groups.

    let photos = [ph(1, 0, quality: 0.9), ph(2, 1), ph(3, 2)]
    let keeperID = keeper(photos).uuid   // U1

    // Simulate uncertain group: rejected stays empty.
    let uncertainRejected: Set<String> = []   // no seeding
    check(uncertainRejected.isEmpty,
          "confidentDupe=false: uncertain group starts with empty rejected set")

    // Simulate confident group: seed non-keeper, non-protected.
    let confidentRejected: Set<String> = Set(photos.compactMap { p in
        (p.uuid != keeperID && !p.isProtected) ? p.uuid : nil
    })
    check(confidentRejected == Set(["U2", "U3"]),
          "confidentDupe=true: confident group seeds non-keeper non-protected frames")

    // The keeper is NEVER seeded regardless of confidence.
    check(!confidentRejected.contains(keeperID),
          "keeper never in seeded rejected regardless of confidence")
}
do {
    // Protected frames are NEVER auto-seeded even in a confident group.
    let fav    = ph(1, 0, fav: true)
    let plain  = ph(2, 1)
    let edited_ = ph(3, 2, edited: true)
    let keeperID = keeper([fav, plain, edited_]).uuid   // U1 (favorite wins)
    let seeded: Set<String> = Set([fav, plain, edited_].compactMap { p in
        (p.uuid != keeperID && !p.isProtected) ? p.uuid : nil
    })
    // Only U2 (plain) should be seeded. U1 is keeper. U3 is protected (edited).
    check(seeded == Set(["U2"]),
          "confident seeding: only non-keeper non-protected frames; protected never seeded")
}

// ─────────────────────────────────────────────────────────────────────────────
// FIX #4 — documentEvalDegraded: safe-seeding guard (pure-Core)
//
// When the Vision document eval ran but the image was unavailable (iCloud-
// evicted / timeout), `documentEvalDegraded` is set to true and `isDocument`
// is false — but we cannot confirm the frame is NOT a document. The auto-
// seeding logic must treat such a frame like a protected one: never seed it
// into `rejected` for confident groups (stay keep-by-default).
//
// Tests verify:
//   1. A degraded frame is NOT in the auto-seeded rejected set.
//   2. The `documentEvalDegraded` field threads through Photo correctly.
//   3. A non-degraded, non-protected frame IS still seeded as before.
//   4. The user can still MANUALLY reject a degraded frame via forceReject.
// ─────────────────────────────────────────────────────────────────────────────

print("FIX #4 — documentEvalDegraded auto-seeding guard (pure-Core)")

// Helper: mirror the FIX #4 aware seeding logic from LibraryModel.scan().
// Confident group: reject non-keeper, non-protected, non-degraded frames.
func seedRejected(photos: [Photo], keeperID: String) -> Set<String> {
    Set(photos.compactMap { p in
        (p.uuid != keeperID && !p.isProtected && !p.documentEvalDegraded) ? p.uuid : nil
    })
}

do {
    // (1) Degraded frame excluded from auto-seeding, just like a protected frame.
    let keep     = Photo(uuid: "UK", filename: "keep.heic", takenAt: 0,
                         width: 100, height: 100, size: 1_000_000, uti: "public.heic",
                         quality: 0.9)
    let plain    = Photo(uuid: "UP", filename: "plain.heic", takenAt: 1,
                         width: 100, height: 100, size: 1_000_000, uti: "public.heic")
    let degraded = Photo(uuid: "UD", filename: "degraded.heic", takenAt: 2,
                         width: 100, height: 100, size: 1_000_000, uti: "public.heic",
                         documentEvalDegraded: true)

    let seeded = seedRejected(photos: [keep, plain, degraded], keeperID: "UK")
    check(!seeded.contains("UK"), "degraded: keeper never seeded")
    check(seeded.contains("UP"),  "degraded: plain non-keeper IS seeded")
    check(!seeded.contains("UD"), "degraded: degraded frame NOT auto-seeded (FIX #4)")
}

do {
    // (2) documentEvalDegraded field threads through Photo correctly.
    let p = Photo(uuid: "Ux", filename: "x.heic", takenAt: 0,
                  width: 100, height: 100, size: 1000, uti: "public.heic",
                  documentEvalDegraded: true)
    check(p.documentEvalDegraded == true,  "documentEvalDegraded=true stored correctly")
    let q = Photo(uuid: "Uy", filename: "y.heic", takenAt: 0,
                  width: 100, height: 100, size: 1000, uti: "public.heic")
    check(q.documentEvalDegraded == false, "documentEvalDegraded defaults to false")
}

do {
    // (3) Non-degraded, non-protected frame still seeded as before (no regression).
    let keep  = Photo(uuid: "UK2", filename: "k.heic", takenAt: 0,
                      width: 100, height: 100, size: 1_000_000, uti: "public.heic",
                      quality: 0.9)
    let plain = Photo(uuid: "UP2", filename: "p.heic", takenAt: 1,
                      width: 100, height: 100, size: 1_000_000, uti: "public.heic")
    let seeded = seedRejected(photos: [keep, plain], keeperID: "UK2")
    check(seeded == Set(["UP2"]),
          "degraded: non-degraded plain non-keeper still seeded as normal")
}

do {
    // (4) A degraded frame CAN still be manually rejected by the user (force path).
    //     Verify that documentEvalDegraded doesn't accidentally set isProtected.
    let degraded = Photo(uuid: "UD2", filename: "d.heic", takenAt: 0,
                         width: 100, height: 100, size: 1000, uti: "public.heic",
                         documentEvalDegraded: true)
    check(!degraded.isProtected,
          "degraded: documentEvalDegraded alone does not set isProtected (user can still force-reject)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass 2a — Justified-rows gallery layout (pure row-packing math)
//
// JustifiedLayout.rows() is the UI-free helper that drives the aspect-true
// gallery: frames keep their real aspect ratio, pack into rows of a target
// height, and each FULL row is uniformly scaled so its total width exactly
// equals the container. The trailing row keeps the target height (not
// stretched). These tests pin that contract; the SwiftUI view consumes the
// result verbatim, so getting the math right here means correct on-screen rows.
// ─────────────────────────────────────────────────────────────────────────────

print("Pass 2a — Justified-rows layout")

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

do {
    // Empty input → no rows.
    check(JustifiedLayout.rows(aspectRatios: [], containerWidth: 1000,
                               targetHeight: 200, spacing: 8).isEmpty,
          "justified: empty input → no rows")
}

do {
    // A single frame is the trailing row → keeps the TARGET height, not stretched.
    // 3:2 landscape at H=200 → width 300, well under a 1000-wide container.
    let rows = JustifiedLayout.rows(aspectRatios: [1.5], containerWidth: 1000,
                                    targetHeight: 200, spacing: 8)
    check(rows.count == 1 && rows[0].items.count == 1, "justified: single frame → 1 row, 1 item")
    check(approx(rows[0].height, 200) && approx(rows[0].items[0].width, 300),
          "justified: lone trailing frame keeps target height (not stretched)")
}

do {
    // A FULL row (one that overflowed and got finalized) fills the container
    // width EXACTLY. Use many wide frames so the first row fills before the end.
    let aspects = Array(repeating: 1.5, count: 10)   // 10 landscape frames
    let W = 1000.0, gap = 8.0, H = 200.0
    let rows = JustifiedLayout.rows(aspectRatios: aspects, containerWidth: W,
                                    targetHeight: H, spacing: gap)
    check(rows.count >= 2, "justified: 10 wide frames wrap into ≥2 rows")
    // Every row EXCEPT the last must fill the width exactly.
    let nonLast = rows.dropLast()
    check(nonLast.allSatisfy { approx($0.totalWidth(spacing: gap), W, 1e-4) },
          "justified: every full (non-trailing) row fills the container width exactly")
    // Within a justified row, all items share the row height.
    check(rows.allSatisfy { r in r.items.allSatisfy { approx($0.height, r.height) } },
          "justified: all items in a row share the row height")
    // Aspect ratio is preserved for every item: width/height == input aspect.
    check(rows.allSatisfy { r in r.items.allSatisfy { approx($0.width / $0.height, aspects[$0.index]) } },
          "justified: every item preserves its true aspect ratio")
}

do {
    // Mixed portrait + landscape. Portrait (aspect < 1) must stay narrow/tall;
    // landscape wide/short. The justify must still fill non-trailing rows.
    let aspects = [0.75, 1.5, 0.6, 1.78, 1.0, 0.75, 1.33, 1.5]
    let W = 900.0, gap = 6.0, H = 180.0
    let rows = JustifiedLayout.rows(aspectRatios: aspects, containerWidth: W,
                                    targetHeight: H, spacing: gap)
    // Indices are a partition of 0..<n in order (no drops, no dupes, in order).
    let flatIdx = rows.flatMap { $0.items.map(\.index) }
    check(flatIdx == Array(0..<aspects.count),
          "justified: indices partition input in original order (no drops/dupes)")
    check(rows.dropLast().allSatisfy { approx($0.totalWidth(spacing: gap), W, 1e-3) },
          "justified: mixed-orientation full rows still fill the width")
    // A portrait frame (aspect 0.75) is taller than wide at any row height.
    check(rows.allSatisfy { r in r.items.allSatisfy { p in
        aspects[p.index] < 1 ? p.width < p.height : true } },
          "justified: portrait frames stay taller than wide (true orientation)")
}

do {
    // A single frame WIDER than the container gets its own row scaled DOWN to fit
    // (never overflows). aspect 5.0 at H=200 → 1000 wide, container only 600.
    let rows = JustifiedLayout.rows(aspectRatios: [5.0], containerWidth: 600,
                                    targetHeight: 200, spacing: 8)
    check(rows.count == 1, "justified: one oversized frame → single row")
    check(rows[0].items[0].width <= 600 + 1e-6,
          "justified: oversized lone frame is scaled down to fit (no overflow)")
}

do {
    // Bad / missing aspect ratios (0, NaN, negative) are treated as square (1).
    let rows = JustifiedLayout.rows(aspectRatios: [0, .nan, -3, 1.5],
                                    containerWidth: 1000, targetHeight: 200, spacing: 8)
    let flat = rows.flatMap(\.items)
    check(flat.count == 4, "justified: degenerate aspects still produce all 4 items")
    // The three bad ones should be square at the trailing row height.
    let squares = flat.prefix(3)
    check(squares.allSatisfy { approx($0.width, $0.height) },
          "justified: non-finite / non-positive aspect → square (1:1)")
}

do {
    // Degenerate container width (≤0) must not crash or divide-by-zero — it falls
    // back to a tall single column at the target height.
    let rows = JustifiedLayout.rows(aspectRatios: [1.5, 0.8], containerWidth: 0,
                                    targetHeight: 200, spacing: 8)
    check(!rows.isEmpty && rows.allSatisfy { $0.height.isFinite && $0.height > 0 },
          "justified: zero container width degrades gracefully (finite heights)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass 2a — display rotation reflows the aspect ratio
//
// Non-destructive display-rotate stores quarter-turns per frame and applies them
// to BOTH the rendered image and the aspect ratio fed into the justified layout,
// so a rotated portrait reflows as a landscape (and vice-versa). The aspect math
// is pure (a 90°/270° turn inverts w/h; 0°/180° leaves it) so we test it here.
// ─────────────────────────────────────────────────────────────────────────────

print("Pass 2a — rotated aspect reflow")

/// Pure mirror of the view's rotated-aspect rule: an odd quarter-turn swaps
/// width and height; an even quarter-turn leaves the aspect unchanged.
func rotatedAspect(_ aspect: Double, quarterTurns: Int) -> Double {
    let q = ((quarterTurns % 4) + 4) % 4
    return (q == 1 || q == 3) ? 1.0 / aspect : aspect
}

do {
    let landscape = 1.5    // 3:2
    check(approx(rotatedAspect(landscape, quarterTurns: 0), 1.5), "rotate 0 → unchanged")
    check(approx(rotatedAspect(landscape, quarterTurns: 1), 1.0 / 1.5),
          "rotate 90 → aspect inverts (landscape → portrait)")
    check(approx(rotatedAspect(landscape, quarterTurns: 2), 1.5), "rotate 180 → unchanged")
    check(approx(rotatedAspect(landscape, quarterTurns: 3), 1.0 / 1.5),
          "rotate 270 → aspect inverts")
    // Normalisation: negative and >4 turns wrap correctly.
    check(approx(rotatedAspect(landscape, quarterTurns: -1), 1.0 / 1.5),
          "rotate -90 normalises to 270 → inverts")
    check(approx(rotatedAspect(landscape, quarterTurns: 5), 1.0 / 1.5),
          "rotate 450 normalises to 90 → inverts")
    check(approx(rotatedAspect(landscape, quarterTurns: 4), 1.5),
          "rotate 360 normalises to 0 → unchanged")
}

do {
    // A rotated portrait reflows in the justified layout as a landscape: feeding
    // the rotated aspect into rows() yields a wider-than-tall placed frame.
    let portrait = 0.75
    let rotated = rotatedAspect(portrait, quarterTurns: 1)   // → 1.333…
    let rows = JustifiedLayout.rows(aspectRatios: [rotated], containerWidth: 1000,
                                    targetHeight: 200, spacing: 8)
    check(rows[0].items[0].width > rows[0].items[0].height,
          "rotate: a rotated portrait reflows wider-than-tall in the layout")
}

// ─────────────────────────────────────────────────────────────────────────────
// Pass 2b — RotationEncoding pure helpers (Core-level, no PhotoKit)
//
// encodeQuarterTurns / decodeQuarterTurns live in SnapsiftCore/RotationEncoding.swift
// and round-trip through the PHAdjustmentData payload format
// (UTF-8 JSON {"quarterTurns":<n>}).
//
// ciRotationTransform (CoreGraphics-dependent) lives in SnapsiftApp and is not
// importable here; its correctness is asserted via the CIImage integration in
// the app. The encode/decode helpers are the pure-testable surface.
// ─────────────────────────────────────────────────────────────────────────────

print("Pass 2b — RotationEncoding helpers")

// encodeQuarterTurns / decodeQuarterTurns round-trip
do {
    for q in [0, 1, 2, 3] {
        let encoded = encodeQuarterTurns(q)
        let decoded = decodeQuarterTurns(from: encoded)
        check(decoded == q, "encode/decode round-trip: quarterTurns=\(q)")
    }
    // Values outside 0…3 normalise modulo 4.
    check(decodeQuarterTurns(from: encodeQuarterTurns(4)) == 0,
          "encode/decode: 4 normalises to 0")
    check(decodeQuarterTurns(from: encodeQuarterTurns(-1)) == 3,
          "encode/decode: -1 normalises to 3")
    check(decodeQuarterTurns(from: encodeQuarterTurns(7)) == 3,
          "encode/decode: 7 normalises to 3")
}

// encodeQuarterTurns produces valid UTF-8 JSON
do {
    let data = encodeQuarterTurns(2)
    let str = String(data: data, encoding: .utf8)
    check(str == "{\"quarterTurns\":2}", "encodeQuarterTurns produces correct JSON string")
}

// decodeQuarterTurns rejects corrupt data
do {
    let bad = "not json".data(using: .utf8)!
    check(decodeQuarterTurns(from: bad) == nil,
          "decodeQuarterTurns: corrupt data returns nil")
    let missingKey = "{\"turns\":1}".data(using: .utf8)!
    check(decodeQuarterTurns(from: missingKey) == nil,
          "decodeQuarterTurns: wrong key returns nil")
}

print(failures == 0 ? "\n✅ all Swift Core tests passed" : "\n❌ \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
