import Foundation
import SnapsiftCore

// Deterministic scan rules, shared with the framework-free tests.
enum PhotoLibraryScanRules {
    /// Near-identical confidence is only a review section; it never seeds rejections.
    static func reviewGroups(_ clusters: [[Photo]], confident: Set<Int> = []) -> [ReviewGroup] {
        clusters.enumerated().map { index, photos in
            var group = ReviewGroup(photos: photos, keeperID: keeper(photos).uuid)
            group.confidentDupe = confident.contains(index)
            return group
        }
    }

    /// Combined keeper key: a Photos extension of Core's `RankKey` that slots
    /// the on-device face score just below favorite (the frame where people look
    /// their best), then mirrors Core exactly: quality, original-camera,
    /// sharpness, format, size, earliest take. Kept in lockstep with `rankKey` so
    /// the face pass can only re-pick the keeper — never resurrect a deleted
    /// signal or change WHICH frames are deletable.
    private struct FaceRankKey: Comparable {
        let favorite: Int, face: Int, core: RankKey
        static func < (a: FaceRankKey, b: FaceRankKey) -> Bool {
            if a.favorite != b.favorite { return a.favorite < b.favorite }
            if a.face != b.face { return a.face < b.face }
            return a.core < b.core   // quality, original-camera, sharpness, uti, size, take
        }
    }
    private static func faceRankKey(_ p: Photo, scores: [String: Double]) -> FaceRankKey {
        FaceRankKey(favorite: p.favorite ? 1 : 0,
                    face: Int(((scores[p.uuid] ?? 0) * 100).rounded()),
                    core: rankKey(p))
    }

    static func refineWithFaces(_ groups: [ReviewGroup], scores: [String: Double]) -> [ReviewGroup] {
        groups.map { g in
            var ng = g
            ng.keeperID = (g.photos.max { faceRankKey($0, scores: scores) < faceRankKey($1, scores: scores) } ?? g.photos[0]).uuid
            // Same invariant as promote(): the keeper must never stay in the
            // rejection set. Without this, a face-refine after marks are seeded
            // can crown a rejected frame and the group's own keeper gets
            // deleted on commit (while the group vanishes from the sheet).
            ng.rejected.remove(ng.keeperID)
            ng.autoSeeded.remove(ng.keeperID)
            return ng
        }
    }

    /// Only a positively unpaired video may enter review; unknown videos need human review.
    static func excludePairedVideos<Item>(
        _ assets: [Item], identifier: (Item) -> String, isVideo: (Item) -> Bool,
        isCancelled: () -> Bool, pairing: (Item) async -> Bool?
    ) async -> (kept: [Item], undetermined: [Item]) {
        let videos = assets.filter(isVideo)
        guard !videos.isEmpty else { return (assets, []) }
        var excluded: Set<String> = []
        var undetermined: [Item] = []
        for video in videos {
            if isCancelled() { break } // cancelling callers discard the partial result
            switch await pairing(video) {
            case .some(true): excluded.insert(identifier(video))
            case .some(false): break
            default:
                excluded.insert(identifier(video))
                undetermined.append(video)
            }
        }
        guard !excluded.isEmpty else { return (assets, []) }
        return (assets.filter { !excluded.contains(identifier($0)) }, undetermined)
    }
}
