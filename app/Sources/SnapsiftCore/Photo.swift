import Foundation

/// One asset in a candidate near-duplicate group. Mirrors the Python `Photo`
/// dataclass field-for-field so the two implementations stay interchangeable.
public struct Photo: Sendable, Equatable, Identifiable {
    public var id: String { uuid }

    public let uuid: String
    public let filename: String
    /// Cocoa-epoch seconds (2001-01-01 UTC). Add `appleEpochOffset` for Unix.
    public let takenAt: Double
    public let width: Int
    public let height: Int
    public let size: Int        // original file size, bytes
    public let uti: String      // uniform type identifier
    public let kind: Int        // 0 = image, 1 = video
    public let favorite: Bool
    public let quality: Double  // composite of Apple's aesthetic scores

    public init(uuid: String, filename: String, takenAt: Double,
                width: Int, height: Int, size: Int, uti: String,
                kind: Int = 0, favorite: Bool = false, quality: Double = 0) {
        self.uuid = uuid
        self.filename = filename
        self.takenAt = takenAt
        self.width = width
        self.height = height
        self.size = size
        self.uti = uti
        self.kind = kind
        self.favorite = favorite
        self.quality = quality
    }
}

/// Cocoa epoch → Unix epoch offset, in seconds.
public let appleEpochOffset: Double = 978_307_200
