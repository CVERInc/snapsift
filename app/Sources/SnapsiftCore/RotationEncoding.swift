import Foundation

// MARK: - Pass 2b — PHAdjustmentData payload helpers (pure, testable)
//
// These encode/decode the PHAdjustmentData payload for the
// "net.cver.snapsift.rotate" adjustment that snapsift writes when saving
// a display rotation permanently to Photos. Keeping them in Core means they
// can be covered by the framework-free test runner (SnapsiftTests) without
// pulling in PhotoKit or CoreGraphics.
//
// Format: UTF-8 JSON `{"quarterTurns":<n>}` where n ∈ {0, 1, 2, 3}.
// Values outside 0…3 are normalised modulo 4 before encoding.

/// Encode a net quarter-turn count into PHAdjustmentData payload bytes.
public func encodeQuarterTurns(_ n: Int) -> Data {
    let net = ((n % 4) + 4) % 4
    return "{\"quarterTurns\":\(net)}".data(using: .utf8)!
}

/// Decode quarter-turns from PHAdjustmentData payload bytes produced by
/// `encodeQuarterTurns`. Returns nil if the data cannot be parsed or the
/// key is missing.
public func decodeQuarterTurns(from data: Data) -> Int? {
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
          let q = dict["quarterTurns"] else { return nil }
    return ((q % 4) + 4) % 4
}
