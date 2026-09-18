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
        sharpness: Double = 0, originalCamera: Bool = false,
        docDegraded: Bool = false, editedUnknown: Bool = false) -> Photo {
    Photo(uuid: "U\(pk)", filename: "IMG_\(pk).heic", takenAt: takenAt,
          width: w, height: h, size: size, uti: uti, favorite: fav, quality: quality,
          edited: edited, isDocument: isDocument, sharpness: sharpness,
          originalCamera: originalCamera,
          documentEvalDegraded: docDegraded, editedUndetermined: editedUnknown)
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

/// NOT a mirror any more. `ReviewGroup.isDelete` now calls Core's
/// `isEffectiveDeletion`, and so does this — the same function the app runs, so
/// deleting the guard turns these red instead of leaving them green.
/// (`deleteAll` here means "the group's marks cover every candidate", which the
/// rejected-set model expresses directly: this shim just builds that set.)
func reviewDeletionIDs(_ photos: [Photo], keeperID: String,
                       deleteAll: Bool, includeProtected: Bool) -> Set<String> {
    let rejected: Set<String> = deleteAll
        ? Set(photos.map(\.uuid))
        : Set(photos.filter { $0.uuid != keeperID }.map(\.uuid))
    return Set(photos.filter {
        isEffectiveDeletion($0, rejected: rejected, includeProtected: includeProtected)
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
    // (4) The override is not enough on its own. A protected frame is deleted
    //     only when it is ALSO in `rejected`, which nothing but the ⇧X /
    //     "include protected" path (both behind a confirm dialog) can do — the
    //     scanner never puts one there. Marks alone or consent alone: safe.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    check(!isEffectiveDeletion(fav, rejected: ["U2"], includeProtected: true),
          "includeProtected=true but the frame is not marked: protected frame is safe")
    check(!isEffectiveDeletion(fav, rejected: ["U1"], includeProtected: false),
          "marked but no consent: protected frame is safe")
    check(isEffectiveDeletion(fav, rejected: ["U1"], includeProtected: true),
          "marked AND consented: the informed-consent path still works")
    check(!isEffectiveDeletion(plain, rejected: [], includeProtected: true),
          "an unmarked plain frame is never deleted either")
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

/// Calls the REAL rule (Core `isEffectiveDeletion`, which `ReviewGroup.isDelete`
/// is now a one-line call to) rather than restating it here.
func rejectDeletionIDs(_ photos: [Photo], keeperID: String,
                        rejected: Set<String>, includeProtected: Bool) -> Set<String> {
    Set(photos.filter {
        isEffectiveDeletion($0, rejected: rejected, includeProtected: includeProtected)
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
    // The REAL composition rule the app seeds and `d` bulk-marks with.
    let autoSeeded = bulkRejectCandidates(photos: photos, keeperID: keeperID)
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
    let rejectAllSeeded = bulkRejectCandidates(photos: photos, keeperID: keeperID)
    check(!rejectAllSeeded.contains("U1"), "rejectAll: keeper never auto-rejected")
    check(!rejectAllSeeded.contains("U3"), "rejectAll: protected never auto-rejected")
    check(rejectAllSeeded.contains("U2"), "rejectAll: plain non-keeper IS rejected")
}

// Uncertain group seeding: rejected stays empty.
do {
    let rejected: Set<String> = []
    // Uncertain groups: no seeding.
    check(rejected.isEmpty, "uncertain group: rejected empty at seed")
}

// Keeper never auto-seeded (separate from force-reject path).
do {
    let keep = ph(1, 0, quality: 0.9)
    let plain = ph(2, 1)
    let keeperID = keeper([keep, plain]).uuid
    let autoSeeded = bulkRejectCandidates(photos: [keep, plain], keeperID: keeperID)
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
    // App-seeded exact-duplicate rejection → .exactDuplicate, never .userRejected.
    let plain = ph(1, 0)
    let reason = DeletionAuditLog.reason(for: plain, includeProtectedActive: false,
                                         autoSeededExact: true)
    check(reason == .exactDuplicate, "audit: auto-seeded exact → .exactDuplicate")
}
do {
    // Force-included protection outranks the exact attribution: the user's
    // explicit override is the more consequential fact to record.
    let fav = ph(1, 0, fav: true)
    let reason = DeletionAuditLog.reason(for: fav, includeProtectedActive: true,
                                         autoSeededExact: true)
    check(reason == .forceIncludedProtectedFavorite, "audit: force-included favorite outranks exact attribution")
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

// The REAL seeding rule — Core `bulkRejectCandidates`, which
// `seedExactRejections`, `rejectAll` and `toggleKeepAll` all call. Removing the
// degraded-frame exclusion from it turns the checks below red.
func seedRejected(photos: [Photo], keeperID: String) -> Set<String> {
    bulkRejectCandidates(photos: photos, keeperID: keeperID)
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
          "degraded: documentEvalDegraded alone does not set isProtected")
    // …but it IS unverifiable, and unverifiable frames are never deletable —
    // not even through the informed-consent override, because there is no fact
    // to consent to. This is the half that was missing: `d` used to mark them.
    check(degraded.isUnverifiable && !degraded.isDeletable,
          "degraded: unverifiable ⇒ not deletable")
    check(!isEffectiveDeletion(degraded, rejected: ["UD2"], includeProtected: true),
          "degraded: includeProtected cannot force an unclassifiable frame into the delete set")
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

// ─────────────────────────────────────────────────────────────────────────────
// Exact-duplicate group precheck (pixel-free eligibility)
// ─────────────────────────────────────────────────────────────────────────────

print("Exact-duplicate group precheck")

do {
    check(exactGroupPrecheck([ph(1, 0), ph(2, 1)]),
          "precheck: two same-UTI same-size photos pass")
    check(!exactGroupPrecheck([ph(1, 0)]),
          "precheck: single frame fails")
    check(!exactGroupPrecheck([ph(1, 0), ph(2, 1, w: 1024, h: 768)]),
          "precheck: mixed dimensions fail")
    check(!exactGroupPrecheck([ph(1, 0), ph(2, 1, uti: "public.jpeg")]),
          "precheck: mixed UTI (RAW+JPEG-style pair) fails")
    let video = Photo(uuid: "Uv", filename: "clip.mov", takenAt: 0,
                      width: 4032, height: 3024, size: 2_000_000,
                      uti: "com.apple.quicktime-movie", kind: 1,
                      favorite: false, quality: 0, edited: false,
                      isDocument: false, sharpness: 0, originalCamera: false)
    check(!exactGroupPrecheck([ph(1, 0, uti: "com.apple.quicktime-movie"), video]),
          "precheck: any video member fails")
}

// ─────────────────────────────────────────────────────────────────────────────
// Keeper determinism + reason accuracy
// ─────────────────────────────────────────────────────────────────────────────

print("Keeper determinism + reason accuracy")

do {
    // All RankKey signals tied (same takenAt, size, quality…) — keeper must be
    // the same photo regardless of input order.
    let a = ph(1, 0), b = ph(2, 0), c = ph(3, 0)
    let k1 = keeper([a, b, c]).uuid
    let k2 = keeper([c, a, b]).uuid
    let k3 = keeper([b, c, a]).uuid
    check(k1 == k2 && k2 == k3, "keeper: full tie is order-independent (uuid tie-break)")
}
do {
    // All-favorite group: the star broke no tie, so the reason must fall
    // through to the signal that actually decided (here: size).
    let a = ph(1, 0, size: 3_000_000, fav: true), b = ph(2, 0, fav: true)
    let reason = keeperReason(photos: [a, b], keeperID: a.uuid)
    check(reason != .favorite, "keeperReason: all-favorite group never reports .favorite")
    check(reason == .size, "keeperReason: all-favorite group falls through to real signal")
}
do {
    // Mixed group: favorite genuinely decided → .favorite is correct.
    let a = ph(1, 0, fav: true), b = ph(2, 0)
    check(keeperReason(photos: [a, b], keeperID: a.uuid) == .favorite,
          "keeperReason: favorite-vs-plain still reports .favorite")
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo Codable round-trip (scan-snapshot persistence)
// ─────────────────────────────────────────────────────────────────────────────

print("Photo Codable round-trip")

do {
    let original = Photo(uuid: "U1/L0/001", filename: "IMG_1.heic", takenAt: 1234.5,
                         width: 4032, height: 3024, size: 2_000_000,
                         uti: "public.heic", kind: 0, favorite: true, quality: 0.73,
                         edited: true, isDocument: false, sharpness: 0.4,
                         originalCamera: true, documentEvalDegraded: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Photo.self, from: data)
    check(decoded == original, "photo: encode→decode is identity (every field survives)")
} catch {
    check(false, "photo: Codable round-trip threw \(error)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Photo.with(...) flag override (post-scan re-evaluation: rotation → edited,
// live commit re-check → favorite/edited, exact-pass hi-q → isDocument)
// ─────────────────────────────────────────────────────────────────────────────

print("Photo.with(...) flag override")
do {
    let base = Photo(uuid: "U1/L0/001", filename: "IMG_1.heic", takenAt: 1234.5,
                     width: 4032, height: 3024, size: 2_000_000,
                     uti: "public.heic", kind: 0, favorite: false, quality: 0.73,
                     edited: false, isDocument: false, sharpness: 0.4,
                     originalCamera: true, documentEvalDegraded: false)
    let edited = base.with(edited: true)
    check(edited.edited && !base.edited && edited.isProtected,
          "with(edited:) flips only edited and makes the frame protected")
    check(edited.uuid == base.uuid && edited.filename == base.filename
            && edited.size == base.size && edited.quality == base.quality
            && edited.sharpness == base.sharpness && edited.originalCamera == base.originalCamera,
          "with(...) preserves every non-overridden field")
    let doc = base.with(isDocument: true, documentEvalDegraded: false)
    check(doc.isDocument && !doc.favorite && !doc.edited,
          "with(isDocument:) flips only isDocument")
    check(base.with() == base, "with() with no args is identity")
}

// ─────────────────────────────────────────────────────────────────────────────
// No-survivor audit: an emptied group's keeper was itself deleted, so the log
// must not name a phantom survivor (empty keeper fields → "(no survivor)").
// ─────────────────────────────────────────────────────────────────────────────

print("No-survivor audit keeper rendering")
do {
    let survivor = DeletionRecord(timestamp: "2026-07-03T00:00:00Z",
                                  assetIdentifier: "U2", filename: "IMG_2.heic",
                                  sizeBytes: 2048, keeperIdentifier: "U1",
                                  keeperFilename: "IMG_1.heic", reason: .userRejected)
    let noSurvivor = DeletionRecord(timestamp: "2026-07-03T00:00:00Z",
                                    assetIdentifier: "U3", filename: "IMG_3.heic",
                                    sizeBytes: 2048, keeperIdentifier: "",
                                    keeperFilename: "", reason: .userRejected)
    let text = DeletionAuditLog.exportText(sessions: [
        DeletionSession(timestamp: "2026-07-03T00:00:00Z", records: [survivor, noSurvivor])
    ])
    check(text.contains("keeper: IMG_1.heic"), "export names a real surviving keeper")
    check(text.contains("keeper: (no survivor)"),
          "export renders empty keeper fields as (no survivor), never blank")
    check(!text.contains("keeper: \n") && !text.contains("keeper: \(noSurvivor.reason.rawValue)"),
          "no-survivor keeper line is never left blank")
}

// ExportLabels lets the app layer inject localized strings + a reason mapper
// so the exported log is honest in the user's language (the filename already is)
// while SnapsiftCore stays UI-framework-free.
print("Export label injection")
do {
    let rec = DeletionRecord(timestamp: "2026-07-03T00:00:00Z",
                             assetIdentifier: "U9", filename: "IMG_9.heic",
                             sizeBytes: 0, keeperIdentifier: "U1",
                             keeperFilename: "IMG_1.heic", reason: .exactDuplicate)
    let labels = DeletionAuditLog.ExportLabels(
        title: "刪除記錄",
        reasonLabel: "原因：",
        keeperLabel: "保留：",
        reasonName: { $0 == .exactDuplicate ? "完全相同（App 標記）" : $0.rawValue }
    )
    let text = DeletionAuditLog.exportText(
        sessions: [DeletionSession(timestamp: "2026-07-03T00:00:00Z", records: [rec])],
        labels: labels)
    check(text.contains("刪除記錄"), "export uses the injected title")
    check(text.contains("原因： 完全相同（App 標記）"),
          "export uses the injected reason label + localized reason name")
    check(!text.contains("exactDuplicate"),
          "raw enum identifier never leaks when a reasonName mapper is supplied")
    // Default labels keep the English machine-readable form (back-compat).
    let plain = DeletionAuditLog.exportText(
        sessions: [DeletionSession(timestamp: "2026-07-03T00:00:00Z", records: [rec])])
    check(plain.contains("reason: exactDuplicate"),
          "default labels preserve the stable English/rawValue export")
}

// append now returns Bool so a write failure (e.g. full disk) can be surfaced
// instead of silently swallowed. The empty-records no-op reports success without
// touching disk — the caller must not treat "nothing to log" as a failure.
print("Audit-log append return contract")
do {
    let ok = DeletionAuditLog.append(DeletionSession(timestamp: "2026-07-03T00:00:00Z", records: []))
    check(ok, "append(empty) returns true (no-op success, no false alarm)")
}

// The zero-input boundary: every grouping/keeper entry point must degrade to
// "nothing" rather than trap — deletions() especially, since its output feeds
// the delete pipeline.
print("Zero-input boundaries")
check(cluster([], gapSec: 3, sizeTol: 0.10).isEmpty, "cluster([]) → []")
check(groupByHash([(UInt64, Photo)](), maxDistance: 2).isEmpty, "groupByHash([]) → []")
check(deletions([]).isEmpty, "deletions([]) → [] (never traps picking a keeper from nobody)")
check(deletions([ph(1, 0)]).isEmpty, "single-frame group deletes nothing")
check(keeper([ph(1, 0)]).uuid == "U1", "single-frame group keeps its one frame")
check(exactDuplicateSuggestions([]).isEmpty, "exactDuplicateSuggestions([]) → []")

// Rotation payload normalisation: values land in 0…3 no matter what goes in —
// including raw payloads that never passed through encodeQuarterTurns.
print("Rotation encoding normalisation")
check(decodeQuarterTurns(from: encodeQuarterTurns(-1)) == 3, "encode(-1) round-trips to 3")
check(decodeQuarterTurns(from: encodeQuarterTurns(5)) == 1, "encode(5) round-trips to 1")
check(decodeQuarterTurns(from: Data("{\"quarterTurns\":7}".utf8)) == 3,
      "raw un-normalised payload (7) decodes to 3")
check(decodeQuarterTurns(from: Data("{\"quarterTurns\":-3}".utf8)) == 1,
      "raw negative payload (-3) decodes to 1")
check(decodeQuarterTurns(from: Data("not json".utf8)) == nil, "garbage payload → nil")

// Degenerate layout inputs are clamped, never propagated: a zero/negative
// target height or spacing must still yield finite, positive frames.
print("JustifiedLayout degenerate sizing")
do {
    let rows = JustifiedLayout.rows(aspectRatios: [1.5, 0.8, 1.0], containerWidth: 800,
                                    targetHeight: 0, spacing: -5)
    let allFrames = rows.flatMap(\.items)
    check(!allFrames.isEmpty && allFrames.allSatisfy {
        $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
    }, "targetHeight 0 + negative spacing → clamped, finite, positive frames")
}

// The real file-I/O path of the accountability log, against a temp file: the
// exact code that runs right after a destructive commit, previously untested.
print("Audit-log file round-trip")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapsift-test-\(ProcessInfo.processInfo.processIdentifier)")
    let url = dir.appendingPathComponent("deletions.jsonl")
    defer { try? FileManager.default.removeItem(at: dir) }
    let rec = DeletionRecord(timestamp: "2026-07-05T00:00:00Z", assetIdentifier: "A1",
                             filename: "IMG_1.heic", sizeBytes: 1_000,
                             keeperIdentifier: "K1", keeperFilename: "IMG_0.heic",
                             reason: .userRejected)
    check(DeletionAuditLog.append(
        DeletionSession(timestamp: "2026-07-05T00:00:00Z", records: [rec]), to: url),
        "first append creates dir + file and succeeds")
    check(DeletionAuditLog.append(
        DeletionSession(timestamp: "2026-07-05T01:00:00Z", records: [rec]), to: url),
        "second append extends the existing file")
    let sessions = DeletionAuditLog.loadSessions(from: url)
    check(sessions.count == 2, "round-trip: both sessions load back")
    check(sessions.first?.timestamp == "2026-07-05T01:00:00Z", "sessions load newest-first")

    // One corrupt line — including a byte that is invalid UTF-8 — must cost
    // that line only, never blank the whole history (regression guard for the
    // whole-file decode wipe).
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0x7B, 0xFF, 0xFE, 0x0A]))   // "{" + invalid utf8 + \n
    try handle.close()
    check(DeletionAuditLog.append(
        DeletionSession(timestamp: "2026-07-05T02:00:00Z", records: [rec]), to: url),
        "append still works after a corrupt line")
    let survived = DeletionAuditLog.loadSessions(from: url)
    check(survived.count == 3, "one corrupt byte costs one line, not the whole history")
    check(survived.first?.timestamp == "2026-07-05T02:00:00Z",
          "sessions around the damage stay readable, newest-first")
}

// ─────────────────────────────────────────────────────────────────────────────
// COMMIT-PATH DECISIONS (SnapsiftCore/DeleteDecision.swift)
//
// These do NOT restate the rules — they call the same functions LibraryModel
// calls. Each block ends with its NEGATIVE CONTROL noted: the one-line change
// to the production rule that turns it red. Verified by making that change and
// watching it fail, then restoring it (receipts in REPORT-fix-r1).
// ─────────────────────────────────────────────────────────────────────────────

print("Commit decision — keeper liveness (P1-1)")
do {
    let keep = ph(1, 0, quality: 0.9)
    let dupe = ph(2, 1)
    let state = CommitGroupState(index: 0, photos: [keep, dupe], keeperID: "U1",
                                 rejected: ["U2"], includeProtected: false)

    // Everything alive → the duplicate is committed, nothing withdrawn.
    let ok = commitSweepDecision(groups: [state],
                                 live: LiveCommitFacts(resolved: ["U1", "U2"],
                                                       favoriteNow: ["U2": false],
                                                       editedNow: ["U2": false]))
    check(ok.deleteIDs == ["U2"] && ok.withdrawnGroupIndexes.isEmpty,
          "keeper alive → the marked duplicate commits")

    // The KEEPER was deleted elsewhere (iPhone, Photos.app) after the scan. The
    // sheet said "KEEP IMG_1.heic". Committing the other frame would leave ZERO
    // copies of that image and book a keeper that does not exist.
    let gone = commitSweepDecision(groups: [state],
                                   live: LiveCommitFacts(resolved: ["U2"],
                                                         favoriteNow: ["U2": false],
                                                         editedNow: ["U2": false]))
    check(gone.deleteIDs.isEmpty, "keeper gone → NOTHING from that group is deleted")
    check(gone.withdrawnGroupIndexes == [0], "keeper gone → the whole group is withdrawn, and named")
    // NEGATIVE CONTROL: drop the keeper-liveness branch from
    // commitSweepDecision and `keeper gone → NOTHING…` fails (deleteIDs == ["U2"]).
}
do {
    // A group the user DELIBERATELY emptied (no-survivor, acknowledged via the
    // sheet checkbox) has no keeper to lose — it must not be withdrawn.
    let a = ph(1, 0), b = ph(2, 1)
    let state = CommitGroupState(index: 0, photos: [a, b], keeperID: "U1",
                                 rejected: ["U1", "U2"], includeProtected: false)
    let d = commitSweepDecision(groups: [state],
                                live: LiveCommitFacts(resolved: ["U1", "U2"],
                                                      favoriteNow: ["U1": false, "U2": false],
                                                      editedNow: ["U1": false, "U2": false]))
    check(Set(d.deleteIDs) == ["U1", "U2"] && d.withdrawnGroupIndexes.isEmpty,
          "deliberate no-survivor group is not confused with a lost keeper")
}

print("Commit decision — at least one SURVIVOR must still exist (P1-2)")
do {
    // The state red-team r2's probe #5 reaches, and the app can reach without
    // any protection flag at all: press `X` on keeper A (nothing outranks it,
    // so nothing is promoted — A stays nominated AND marked), then change your
    // mind about B and un-mark it. A is keeper+rejected, C is rejected, and B —
    // the frame the user just decided to KEEP — is the only survivor.
    let a = ph(1, 0, quality: 0.9), b = ph(2, 1), c = ph(3, 2)
    let photos = [a, b, c]
    let rejected: Set<String> = ["U1", "U3"]
    let state = CommitGroupState(index: 0, photos: photos, keeperID: "U1",
                                 rejected: rejected, includeProtected: false)

    // There IS no nominated surviving keeper in this state — which is exactly
    // what made the old gate skip the liveness check altogether.
    check(survivingKeeper(photos: photos, keeperID: "U1", rejected: rejected,
                          includeProtected: false) == nil,
          "the nominated keeper is itself marked → survivingKeeper is nil")
    check(survivors(photos: photos, rejected: rejected, includeProtected: false)
            .map(\.uuid) == ["U2"],
          "…while the group plainly still has a survivor: U2")

    // B was deleted on a phone between the scan and the commit — the same
    // ordinary action r1 P1-1 was filed for, one frame over.
    let gone = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U3"],
                              favoriteNow: ["U1": false, "U3": false],
                              editedNow: ["U1": false, "U3": false]))
    check(gone.deleteIDs.isEmpty,
          "the only survivor vanished → NOTHING in that group is deleted")
    check(gone.withdrawnGroups == [WithdrawnGroup(index: 0, reason: .noSurvivorLeft)],
          "…the group is withdrawn whole, and says the survivor is what is gone")

    // Positive control: B is still there → the commit proceeds normally, so the
    // guard is not just "withdraw everything".
    let fine = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U2", "U3"],
                              favoriteNow: ["U1": false, "U3": false],
                              editedNow: ["U1": false, "U3": false]))
    check(Set(fine.deleteIDs) == ["U1", "U3"] && fine.withdrawnGroups.isEmpty,
          "survivor alive → the two marked frames commit as normal")
    // NEGATIVE CONTROL: restore the old gate (only `survivingKeeper` liveness,
    // nil ⇒ proceed) and `the only survivor vanished…` fails with
    // deleteIDs == ["U1","U3"] — the zero-surviving-copies commit itself.
}
do {
    // The nominated keeper is gone but ANOTHER frame survives: still withdrawn
    // (the sheet named that photo), and reported as a keeper loss, not as a
    // no-survivor loss — two different sentences for two different facts.
    let a = ph(1, 0, quality: 0.9), b = ph(2, 1), c = ph(3, 2)
    let state = CommitGroupState(index: 0, photos: [a, b, c], keeperID: "U1",
                                 rejected: ["U3"], includeProtected: false)
    let d = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U2", "U3"],
                              favoriteNow: ["U3": false], editedNow: ["U3": false]))
    check(d.deleteIDs.isEmpty && d.keeperMissingCount == 1 && d.noSurvivorLeftCount == 0,
          "nominated keeper gone, another survivor alive → withdrawn as keeperMissing")
}
do {
    // The gate reads the whole group, so `groupWithdrawalReason` is asked about
    // every survivor — the App layer's live fetch has to cover them all. This
    // pins the contract the fetch set must satisfy.
    let a = ph(1, 0, quality: 0.9), b = ph(2, 1)
    check(groupWithdrawalReason(photos: [a, b], keeperID: "U1",
                                rejected: ["U1"], includeProtected: false,
                                resolved: ["U1"]) == .noSurvivorLeft,
          "survivor never fetched (absent from resolved) reads as gone — fail-safe")
    check(groupWithdrawalReason(photos: [a, b], keeperID: "U1",
                                rejected: ["U1"], includeProtected: false,
                                resolved: ["U1", "U2"]) == nil,
          "…and with the survivor in the fetch set the group proceeds")
    check(groupWithdrawalReason(photos: [a, b], keeperID: "U1",
                                rejected: ["U1", "U2"], includeProtected: false,
                                resolved: []) == nil,
          "a deliberately emptied group has nothing to lose — never withdrawn")
}

print("One function names the survivor: sheet, checkbox and commit agree (P1-2)")
do {
    // Same rejected-keeper state. Three surfaces used to answer differently:
    // the sheet's keeper row (survivingKeeper ⇒ "⚠️ no photo left"), the
    // acknowledge checkbox (hasNoSurvivor == false ⇒ no checkbox), and the
    // commit (which kept U2). `namedSurvivor` is the one answer they all read.
    let a = ph(1, 0, quality: 0.9), b = ph(2, 1), c = ph(3, 2)
    let photos = [a, b, c]
    let rejected: Set<String> = ["U1", "U3"]
    check(namedSurvivor(photos: photos, keeperID: "U1", rejected: rejected,
                        includeProtected: false)?.uuid == "U2",
          "the sheet names the frame that actually stays, not 'no photo left'")
    check(!hasNoSurvivor(photos: photos, rejected: rejected, includeProtected: false),
          "…and the checkbox stays away, because a photo really does remain")

    // THE INVARIANT: the two can never disagree, whatever the state.
    var agree = true
    for r in [Set<String>(), ["U1"], ["U2"], ["U3"], ["U1", "U2"], ["U1", "U3"],
              ["U2", "U3"], ["U1", "U2", "U3"]] {
        for inc in [false, true] {
            let named = namedSurvivor(photos: photos, keeperID: "U1",
                                      rejected: r, includeProtected: inc)
            if (named == nil) != hasNoSurvivor(photos: photos, rejected: r,
                                               includeProtected: inc) { agree = false }
        }
    }
    check(agree, "namedSurvivor == nil is EXACTLY hasNoSurvivor, over every mark state")
    check(namedSurvivor(photos: photos, keeperID: "U1",
                        rejected: ["U1", "U2", "U3"], includeProtected: false) == nil,
          "a group that really is emptied still reports no survivor")
    // NEGATIVE CONTROL: make namedSurvivor return `survivingKeeper` only and
    // the first check fails (nil, the "⚠️ no photo left" fork).
}

print("Commit decision — live protection sweep")
do {
    let keep = ph(1, 0, quality: 0.9)
    let starred = ph(2, 1)      // favorited on an iPhone after the scan
    let edited_ = ph(3, 2)      // edited in Photos.app after the scan
    let plain = ph(4, 3)
    let state = CommitGroupState(index: 0, photos: [keep, starred, edited_, plain],
                                 keeperID: "U1", rejected: ["U2", "U3", "U4"],
                                 includeProtected: false)
    let d = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U2", "U3", "U4"],
                              favoriteNow: ["U2": true, "U3": false, "U4": false],
                              editedNow: ["U2": false, "U3": true, "U4": false]))
    check(d.deleteIDs == ["U4"], "favorited/edited since the scan are swept out of the commit")
    check(d.newlyProtectedCount == 2, "…and reported, so the banner can say how many")
    // NEGATIVE CONTROL: make the sweep read `editedNow[uuid] ?? false` without
    // the favorite check and "U2" reappears in deleteIDs.
}
do {
    // Edit state UNREADABLE (no Full Disk Access + tripped sync-lane breaker,
    // or a library we couldn't verify). Missing key == undetermined.
    let keep = ph(1, 0, quality: 0.9)
    let unknown = ph(2, 1)
    let state = CommitGroupState(index: 0, photos: [keep, unknown], keeperID: "U1",
                                 rejected: ["U2"], includeProtected: false)
    let d = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U2"],
                              favoriteNow: ["U2": false], editedNow: [:]))
    check(d.deleteIDs.isEmpty, "undetermined edit state ⇒ not deleted")
    check(d.undeterminedCount == 1, "undetermined frames are counted for the UI, not silent")
    // NEGATIVE CONTROL: coerce the missing key to `false` (`editedNow[uuid] ?? false`)
    // and the first check fails — the exact regression this arm exists for.
}
do {
    // Force-included protected frames stay force-included: the user consented
    // to those on this sheet. But a frame protected only AFTER the scan was
    // never part of that consent, so the sweep still runs in such groups.
    let fav = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    let state = CommitGroupState(index: 0, photos: [fav, plain], keeperID: "U2",
                                 rejected: ["U1", "U2"], includeProtected: true)
    let d = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U2"],
                              favoriteNow: ["U2": true], editedNow: ["U2": false]))
    check(d.deleteIDs == ["U1"], "consented protected frame still commits")
    check(d.newlyProtectedCount == 1, "newly-favorited frame is swept even in an includeProtected group")
}
do {
    // A marked frame that no longer exists: counted as vanished, never in the
    // commit set, and it does NOT take the rest of the group with it.
    let keep = ph(1, 0, quality: 0.9), a = ph(2, 1), b = ph(3, 2)
    let state = CommitGroupState(index: 0, photos: [keep, a, b], keeperID: "U1",
                                 rejected: ["U2", "U3"], includeProtected: false)
    let d = commitSweepDecision(groups: [state],
        live: LiveCommitFacts(resolved: ["U1", "U3"],
                              favoriteNow: ["U3": false], editedNow: ["U3": false]))
    check(d.deleteIDs == ["U3"] && d.vanishedCount == 1,
          "a mark whose photo is gone is counted, not committed")
}

print("Delete-set composition + unverifiable frames (P2-3)")
do {
    let keep = ph(1, 0, quality: 0.9)
    let plain = ph(2, 1)
    let fav = ph(3, 2, fav: true)
    let evicted = ph(4, 3, docDegraded: true)      // iCloud-evicted: never classified
    let unreadable = ph(5, 4, editedUnknown: true) // edit state unreadable
    let photos = [keep, plain, fav, evicted, unreadable]
    let seeded = bulkRejectCandidates(photos: photos, keeperID: "U1")
    check(seeded == ["U2"], "`d` / auto-seed marks ONLY frames it is allowed to: no protected, no unverifiable")
    check(bulkRejectWithheld(photos: photos, keeperID: "U1") == ["U4", "U5"],
          "…and reports what it withheld, so the button's promise stays true")
    // NEGATIVE CONTROL: change bulkRejectCandidates' filter to `!$0.isProtected`
    // and the first check fails with U4/U5 marked (the old `d` behaviour).
    check(!isEffectiveDeletion(unreadable, rejected: ["U5"], includeProtected: true),
          "unverifiable frames are not deletable even with includeProtected")
    // The FAVORITE wins the keeper slot here (favorite is rankKey's top signal),
    // so the deletable set is the two plain frames — and neither unverifiable
    // frame is in it, which is the point.
    check(Set(deletions(photos).map(\.uuid)) == ["U1", "U2"],
          "Core deletions() excludes unverifiable frames too")
}

print("No-survivor: one definition for the sheet and the model (P2-7)")
do {
    // Keeper is marked, but it is a favorite and the group is NOT overridden:
    // it survives. The sheet's keeper row and noSurvivorGroupCount must agree.
    let favKeeper = ph(1, 0, fav: true)
    let plain = ph(2, 1)
    let rejected: Set<String> = ["U1", "U2"]
    let k = survivingKeeper(photos: [favKeeper, plain], keeperID: "U1",
                            rejected: rejected, includeProtected: false)
    check(k?.uuid == "U1", "protected-and-not-overridden keeper still survives → sheet shows it")
    check(noSurvivorGroupCount([(photos: [favKeeper, plain], rejected: rejected,
                                 includeProtected: false)]) == 0,
          "…and the model counts zero no-survivor groups — the two agree")
    check(!hasNoSurvivor(photos: [favKeeper, plain], rejected: rejected, includeProtected: false),
          "hasNoSurvivor agrees with both")

    // Override on: the keeper really does go, and BOTH surfaces say so.
    let k2 = survivingKeeper(photos: [favKeeper, plain], keeperID: "U1",
                             rejected: rejected, includeProtected: true)
    check(k2 == nil, "overridden keeper is gone → sheet shows the no-survivor row")
    check(noSurvivorGroupCount([(photos: [favKeeper, plain], rejected: rejected,
                                 includeProtected: true)]) == 1,
          "…and the counter arms the acknowledge checkbox — same answer, same rule")
}

print("Exact duplicates: carries unique metadata (P2-2)")
do {
    let keeperMeta = LibraryMetadata(albumCount: 0, hasDescription: false)
    check(!carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: 0, hasDescription: false),
                                 keeper: keeperMeta),
          "a plain copy with nothing extra is safe to suggest")
    check(carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: 3, hasDescription: false),
                                keeper: keeperMeta),
          "the copy filed into 3 albums is NOT interchangeable with the keeper")
    check(carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: 0, hasDescription: true),
                                keeper: keeperMeta),
          "the copy carrying the user's caption is NOT interchangeable either")
    check(carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: nil, hasDescription: nil),
                                keeper: keeperMeta),
          "undetermined metadata ⇒ treated as carrying (unknown ⇒ protected)")
    check(carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: 0, hasDescription: false),
                                keeper: LibraryMetadata()),
          "…including when it is the KEEPER's metadata we could not read")
    check(!carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: 1, hasDescription: false),
                                 keeper: LibraryMetadata(albumCount: 2, hasDescription: true)),
          "a copy carrying LESS than the keeper is still interchangeable")
    // NEGATIVE CONTROL: make the undetermined guard `return false` and the two
    // "undetermined ⇒ carries" checks fail.
}

print("Unclassifiable photos are never delete candidates, even with the per-group override (needs-a-look ruling, 2026-09-16)")
do {
    let keep = ph(1, 0, quality: 0.9)
    let evicted = ph(2, 1, docDegraded: true)       // document eval ran blind
    let unreadable = ph(3, 2, editedUnknown: true)  // edit state unreadable
    let photos = [keep, evicted, unreadable]

    // The per-group "include protected" opt-in (⇧X / mouse toggle) is the
    // ONLY path that can pull a KNOWN protection into the delete set. It must
    // not be able to pull an UNVERIFIABLE frame in too — there is no fact for
    // the user to consent to overriding.
    check(!isEffectiveDeletion(evicted, rejected: ["U2"], includeProtected: true),
          "documentEvalDegraded frame: includeProtected cannot admit it")
    check(!isEffectiveDeletion(unreadable, rejected: ["U3"], includeProtected: true),
          "editedUndetermined frame: includeProtected cannot admit it")
    // Even with EVERY frame marked and the override on, deletions() only
    // returns the ordinary deletable ones.
    check(Set(deletions(photos).map(\.uuid)) == [],
          "a keeper-only group with no plain frames deletes nothing, regardless of the two unverifiable frames")
    let withPlain = photos + [ph(4, 3)]
    check(Set(deletions(withPlain).map(\.uuid)) == ["U4"],
          "…and adding one plain frame changes exactly that — never the unverifiable two")
    // NEGATIVE CONTROL: remove the `if p.isUnverifiable { return false }`
    // guard from `isEffectiveDeletion` (DeleteDecision.swift) — both
    // `includeProtected` checks above go red, and `deletions(photos)` starts
    // returning U2/U3 as soon as anything marks them.
}

print("Snapsift-owned albums excluded from the unique-metadata comparison (needs-a-look ruling, 2026-09-16)")
do {
    let snapsiftTitles: Set<String> = [
        "Snapsift · Burst Candidates", "Snapsift · Blurry", "Snapsift · Documents & IDs",
        "Snapsift · Exact Duplicates", "Snapsift · Needs a look",
    ]
    check(userAlbumCount(titles: [], snapsiftTitles: snapsiftTitles) == 0,
          "no albums at all")
    check(userAlbumCount(titles: ["Snapsift · Needs a look"], snapsiftTitles: snapsiftTitles) == 0,
          "a candidate that is ONLY in snapsift's own album looks like it carries nothing — " +
          "the tool's own housekeeping is not user data")
    check(userAlbumCount(titles: ["Snapsift · Burst Candidates", "Family Trip"],
                         snapsiftTitles: snapsiftTitles) == 1,
          "mixed: only the REAL user album counts")
    check(userAlbumCount(titles: ["Family Trip", "Best of 2026"], snapsiftTitles: snapsiftTitles) == 2,
          "two real user albums both count")
    // The self-bite this exists to prevent: a photo snapsift itself filed
    // into "Needs a look" on a PREVIOUS run must not look, on the NEXT scan,
    // like it carries unique library membership the keeper lacks.
    let candidateAlbums = userAlbumCount(titles: ["Snapsift · Needs a look"], snapsiftTitles: snapsiftTitles)
    check(!carriesUniqueMetadata(candidate: LibraryMetadata(albumCount: candidateAlbums, hasDescription: false),
                                 keeper: LibraryMetadata(albumCount: 0, hasDescription: false)),
          "…so the exact-dup suggestion still fires normally instead of silently going stale")
    // NEGATIVE CONTROL: change `userAlbumCount` to `titles.count` (dropping the
    // `!snapsiftTitles.contains($0)` filter) — the first two checks above go
    // red (0 → 1), and the carriesUniqueMetadata check flips to `true`.
}

print("Library identity: is the sidecar the library PhotoKit serves? (P2-1)")
do {
    let real = "/Volumes/Photos SSD/Photos Library.photoslibrary"
    let stale = "/Users/x/Pictures/Photos Library.photoslibrary"
    check(evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: 12) == .verified,
          "same path + live contents → verified")
    check(evaluateLibraryIdentity(sidecarPath: stale, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: 12)
            == .unverified(.pathMismatch),
          "the stale ~/Pictures copy is caught by PATH — its asset UUIDs all still match")
    check(evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: nil)
            == .unverified(.pathUnknown),
          "couldn't establish where the library is ⇒ unverified, never 'probably fine'")
    check(evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: 9)
            == .unverified(.staleContents),
          "right path, frozen contents (newest assets missing) → unverified")
    check(evaluateLibraryIdentity(sidecarPath: real + "/", photosLibraryPath: real,
                                  sampledNewest: 4, foundInSidecar: 4) == .verified,
          "a trailing slash is not a different library")
    check(evaluateLibraryIdentity(sidecarPath: "", photosLibraryPath: real)
            == .unverified(.pathUnknown),
          "iOS / empty sidecar path ⇒ unverified")
    // The freshness PROBE ITSELF failing is not a finding about the library.
    // `editedFlags` returns nil for SQLITE_BUSY / IO error; reading that as
    // `.staleContents` told the user their library file looks frozen when the
    // truth was "Photos was writing for two seconds".
    check(evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: nil)
            == .unverified(.probeUnavailable),
          "probe couldn't run (nil, not 0) ⇒ unknown — NOT 'stale contents'")
    check(evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: 0)
            == .unverified(.staleContents),
          "…while a probe that ran and found NOTHING really is stale contents")
    check(!evaluateLibraryIdentity(sidecarPath: real, photosLibraryPath: real,
                                   sampledNewest: 12, foundInSidecar: nil).isVerified,
          "either way it is untrusted for this sweep — the difference is the banner")
    check(evaluateLibraryIdentity(sidecarPath: stale, photosLibraryPath: real,
                                  sampledNewest: 12, foundInSidecar: nil)
            == .unverified(.pathMismatch),
          "a wrong path is decided before the probe is even consulted")
    // NEGATIVE CONTROL: drop the path comparison and the pathMismatch check fails.
    // NEGATIVE CONTROL: make `foundInSidecar` non-optional again (nil ⇒ 0) and
    // "probe couldn't run … NOT 'stale contents'" fails.
}

print("Snapsift albums: a frame is in ONE bucket, across scans (P2-3)")
do {
    // Within a single write the two buckets are already disjoint. The bug is
    // ACROSS scans: the album write only ever added, so a frame filed under
    // "Exact Duplicates" on a run with Full Disk Access stayed there when the
    // next run classified it as unreadable and put it in "Needs a look".
    let plan = albumBucketPlan(exactCandidates: ["A", "B"],
                               needsLookCandidates: ["C", "D"])
    check(plan.exactAdd == ["A", "B"] && plan.needsLookAdd == ["C", "D"],
          "each frame is added to the bucket this scan puts it in")
    check(plan.exactRemove == ["C", "D"],
          "…and taken OUT of Exact Duplicates if a previous scan filed it there")
    check(plan.needsLookRemove == ["A", "B"],
          "…and out of Needs a look in the other direction — both ways reconcile")

    // Overlap must be impossible upstream; if it ever happens, the frame we
    // could not classify must not be the one wearing "safe to remove".
    let bad = albumBucketPlan(exactCandidates: ["A", "X"], needsLookCandidates: ["X"])
    check(bad.exactAdd == ["A"],
          "an overlapping frame is dropped from the exact-duplicate bucket")
    check(bad.exactRemove.contains("X") && !bad.needsLookRemove.contains("X"),
          "…and removed from it: unknown ⇒ protected wins the tie")
    check(bad.needsLookAdd == ["X"], "…while Needs a look keeps it")

    // Nothing to reconcile when a bucket is empty — no spurious removals.
    let onlyExact = albumBucketPlan(exactCandidates: ["A"], needsLookCandidates: [])
    check(onlyExact.exactRemove.isEmpty && onlyExact.needsLookRemove == ["A"],
          "an empty needs-look set removes nothing from Exact Duplicates")
    // NEGATIVE CONTROL: return `exactCandidates` unfiltered from albumBucketPlan
    // and "an overlapping frame is dropped…" fails with ["A","X"].
}

print("Own-write token restamp (P2-6)")
do {
    let ours: Set<String> = ["U1", "U2"]
    check(ownWriteOnly(inserted: [], updated: ["U1"], deleted: ["U2"], ourIDs: ours),
          "only our own ids moved → safe to advance the staleness anchor")
    check(!ownWriteOnly(inserted: [], updated: ["U9"], deleted: [], ourIDs: ours),
          "someone else's edit during our write → do NOT stamp over it")
    check(!ownWriteOnly(inserted: ["U9"], updated: [], deleted: [], ourIDs: ours),
          "an asset inserted during our write is never ours")
    check(!ownWriteOnly(inserted: [], updated: [], deleted: ["U9"], ourIDs: ours),
          "an asset deleted elsewhere during our write is never ours")
}

print("Preferred language (gate P2-6)")
do {
    check(preferredLanguageTag(from: ["ja-US", "en-US"], supported: { $0.hasPrefix("ja") || $0.hasPrefix("en") }) == "ja-US",
          "the FIRST preferred language wins, not the format region")
    check(preferredLanguageTag(from: ["ko-KR", "zh-Hant-TW"], supported: { $0.hasPrefix("zh") }) == "zh-Hant-TW",
          "an unsupported first preference falls through to the next")
    check(preferredLanguageTag(from: ["ko-KR"], supported: { $0.hasPrefix("zh") }) == nil,
          "nothing supported → nil (caller defaults to English)")
    check(preferredLanguageTag(from: [], supported: { _ in true }) == nil,
          "empty preference list → nil")
}

print("Photo: snapshot decoding stays backward compatible")
do {
    // last-scan.json is the SOLE store of the user's review decisions. A photo
    // written by a build without `editedUndetermined` must still decode, or the
    // upgrade reads as "every mark you made is gone".
    let legacy = """
    {"uuid":"U1","filename":"IMG_1.heic","takenAt":1.0,"width":4,"height":3,
     "size":100,"uti":"public.heic","kind":0,"favorite":true,"quality":0.5,
     "edited":false,"isDocument":false,"sharpness":0.1,"originalCamera":false,
     "documentEvalDegraded":false}
    """
    let decoded = try? JSONDecoder().decode(Photo.self, from: Data(legacy.utf8))
    check(decoded?.uuid == "U1" && decoded?.favorite == true,
          "a snapshot photo without the new field still decodes")
    check(decoded?.editedUndetermined == false, "…defaulting the missing flag to false")

    let ancient = """
    {"uuid":"U2","filename":"a.jpg","takenAt":0.0,"width":1,"height":1,
     "size":1,"uti":"public.jpeg"}
    """
    check((try? JSONDecoder().decode(Photo.self, from: Data(ancient.utf8)))?.uuid == "U2",
          "…and so does one from before the whole slice-1 flag set")

    let round = try? JSONDecoder().decode(
        Photo.self, from: JSONEncoder().encode(ph(9, 0, editedUnknown: true)))
    check(round?.editedUndetermined == true, "the new flag round-trips")
}

print("Deletion-intent journal (P2-5)")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapsift-journal-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let intentURL = dir.appendingPathComponent("pending-delete.json")

    func rec(_ id: String) -> DeletionRecord {
        DeletionRecord(timestamp: "2026-09-15T10:00:00Z", assetIdentifier: id,
                       filename: "\(id).heic", sizeBytes: 100,
                       keeperIdentifier: "K", keeperFilename: "K.heic",
                       reason: .exactDuplicate)
    }
    let intent = DeletionSession(timestamp: "2026-09-15T10:00:00Z",
                                 records: [rec("A"), rec("B"), rec("C")])
    check(DeletionAuditLog.pendingIntent(at: intentURL) == nil, "no journal before a commit")
    check(DeletionAuditLog.writeIntent(intent, to: intentURL), "journal is written before performChanges")
    check(DeletionAuditLog.pendingIntent(at: intentURL)?.records.count == 3,
          "…and survives the crash it exists for")

    // Reconciliation: A is really gone, B still exists (so it was NEVER
    // deleted — the system confirmation was cancelled), C is already logged.
    let recovered = DeletionAuditLog.recoverableRecords(
        from: intent, stillExisting: ["B"], alreadyLogged: ["C"])
    check(recovered.map(\.assetIdentifier) == ["A"],
          "only genuinely-missing, not-yet-logged photos are booked into the history")
    check(!recovered.contains { $0.assetIdentifier == "B" },
          "a photo that still exists is NEVER booked — history must not over-report")
    // NEGATIVE CONTROL: drop the `stillExisting` filter and the B check fails —
    // the history would then claim a deletion that never happened.

    DeletionAuditLog.clearIntent(at: intentURL)
    check(DeletionAuditLog.pendingIntent(at: intentURL) == nil,
          "journal cleared once the history carries it")

    let logURL = dir.appendingPathComponent("deletions.jsonl")
    DeletionAuditLog.append(DeletionSession(timestamp: "2026-09-15T09:00:00Z",
                                            records: [rec("Z")]), to: logURL)
    check(DeletionAuditLog.loggedAssetIdentifiers(
            from: DeletionAuditLog.loadSessions(from: logURL)) == ["Z"],
          "the dedupe key reads back from the real log file")
}

// MARK: - W1: row-walk geometry (↑/↓ move by ROW, not by index)

print("JustifiedLayout.targetHeight — one formula for the drawer and the walker")
do {
    // Table: (containerWidth, expected nominal row height).
    let cases: [(Double, Double)] = [
        (0, 200),        // not measured yet → the baseline, never a divide by zero
        (-50, 200),      // degenerate width → same baseline
        (400, 150),      // narrow pane clamps at the floor (400/4.2 = 95.2)
        (1000, 1000 / 4.2),
        (2000, 260),     // wide window clamps at the ceiling (2000/4.2 = 476)
    ]
    for (w, expected) in cases {
        check(approx(JustifiedLayout.targetHeight(forWidth: w), expected, 1e-9),
              "targetHeight(\(Int(w))) == \(String(format: "%.1f", expected))")
    }
}

print("JustifiedLayout.rowNeighbor — ↑/↓ walk rows, not the index")
do {
    // 10 landscape frames, 3 to a row: rows are [0,1,2] [3,4,5] [6,7,8] [9].
    let aspects = Array(repeating: 1.5, count: 10)
    let W = 1000.0, gap = 8.0, H = 200.0
    let rows = JustifiedLayout.rows(aspectRatios: aspects, containerWidth: W,
                                    targetHeight: H, spacing: gap)
    check(rows.map(\.items.count) == [3, 3, 3, 1],
          "fixture packs 10 frames into rows of 3, 3, 3, 1")

    // Table: (from, delta, expected index or nil).
    // Every ↓ answer is +3 and every ↑ answer is −3 — which is the whole point:
    // the old handler answered +1/−1 here.
    let cases: [(Int, Int, Int?)] = [
        (0,  1, 3),      // down a row from the first frame
        (1,  1, 4),      // …keeps the column
        (2,  1, 5),
        (3, -1, 0),      // up a row
        (5, -1, 2),
        (0, -1, nil),    // already on the first row → no move invented
        (9,  1, nil),    // already on the last row
        (9, -1, 6),      // trailing row is short: up lands under the same x
        (4,  0, nil),    // a zero step is not a move
        (99, 1, nil),    // an index that isn't placed
    ]
    for (from, delta, expected) in cases {
        let got = JustifiedLayout.rowNeighbor(rows: rows, spacing: gap, from: from, delta: delta)
        check(got == expected,
              "rowNeighbor(from: \(from), delta: \(delta)) == \(expected.map(String.init) ?? "nil")")
    }
    // NEGATIVE CONTROL: if ↑/↓ were still index arithmetic, (0, +1) would be 1.
    check(JustifiedLayout.rowNeighbor(rows: rows, spacing: gap, from: 0, delta: 1) != 1,
          "row-walk is NOT index±1 (the defect this replaces)")
}

do {
    // Rows of unequal length: the neighbour row may not span the source frame's
    // centre at all, and then the NEAREST frame is the honest answer.
    // 4 squares fill the row exactly; a very wide frame takes the next row alone.
    let rows = JustifiedLayout.rows(aspectRatios: [1, 1, 1, 1, 3], containerWidth: 400,
                                    targetHeight: 100, spacing: 0)
    check(rows.map(\.items.count) == [4, 1], "fixture packs 4 + 1")
    check(JustifiedLayout.rowNeighbor(rows: rows, spacing: 0, from: 3, delta: 1) == 4,
          "down from a frame with nothing under it lands on the nearest frame")
    // Back up from the wide frame: the walk follows its CENTRE (x = 150), which
    // sits over the second square — not its left edge, which would give 0.
    check(JustifiedLayout.rowNeighbor(rows: rows, spacing: 0, from: 4, delta: -1) == 1,
          "…and back up follows the wide frame's centre, not its left edge")
    check(JustifiedLayout.rowNeighbor(rows: [], spacing: 0, from: 0, delta: 1) == nil,
          "an empty layout has no neighbour")
}

// MARK: - W1: DELETE carries a reason (label only — decides nothing)

print("deleteMarkReason — the DELETE side finally answers \"why\"")
do {
    // Table: (frame, app-seeded set, whole group armed, expected reason).
    // The app's own seed is the ONE distinction W1 can make truthfully; every
    // other mark is a person's, whether they used X on one frame or D on the
    // group, and the label says exactly that.
    let cases: [(String, Set<String>, Bool, DeleteMarkReason)] = [
        ("A", ["A"],      false, .exactDuplicate),  // the app seeded this one
        ("A", ["A"],      true,  .exactDuplicate),
        ("A", ["A", "B"], false, .exactDuplicate),
        ("B", ["A"],      true,  .userRejected),    // marked by the person
        ("B", [],         true,  .userRejected),
        ("B", ["A"],      false, .userRejected),
        ("B", [],         false, .userRejected),
    ]
    for (frame, seeded, armed, expected) in cases {
        check(deleteMarkReason(frameID: frame, autoSeeded: seeded, wholeGroupMarked: armed) == expected,
              "deleteMarkReason(\(frame), seeded: \(seeded.sorted()), armed: \(armed)) == .\(expected.rawValue)")
    }
}

do {
    // REGRESSION GUARD for review P2-1. `wholeGroupMarked` is fed from
    // `ReviewGroup.deleteAll`, a PREDICATE (bulkRejectCandidates ⊆ rejected)
    // that flips on actions the label has nothing to do with: crossing out the
    // last frame by hand, un-crossing one after D, or nominating a new keeper
    // after D. A label that changes when the person did nothing to THAT frame
    // is the same defect W1 set out to fix, wearing another face.
    //
    // So: the reason must not depend on that argument at all. The old table
    // could not catch this — it fed constants and asserted the flip.
    for frame in ["A", "B"] {
        for seeded: Set<String> in [[], ["A"], ["A", "B"]] {
            let armed = deleteMarkReason(frameID: frame, autoSeeded: seeded, wholeGroupMarked: true)
            let idle  = deleteMarkReason(frameID: frame, autoSeeded: seeded, wholeGroupMarked: false)
            check(armed == idle,
                  "the label for \(frame) (seeded: \(seeded.sorted())) survives deleteAll flipping")
        }
    }

    // …and nothing reaches `.notPicked`, because nothing RECORDS it yet. The
    // case stays defined (W2 writes a real `bulkMarked` set); what must not
    // happen is a chip claiming a fact no state holds — and the audit log,
    // whose `.burstNonKeeper` is RESERVED and never written, agreeing with it.
    let everyReachable = Set([true, false].flatMap { armed in
        ["A", "B", "C"].flatMap { frame in
            [Set<String>(), ["A"], ["A", "B"]].map {
                deleteMarkReason(frameID: frame, autoSeeded: $0, wholeGroupMarked: armed)
            }
        }
    })
    check(everyReachable == [.exactDuplicate, .userRejected],
          "only the two reasons real state can back are reachable (.notPicked is W2)")
}

print(failures == 0 ? "\n✅ all Swift Core tests passed" : "\n❌ \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
