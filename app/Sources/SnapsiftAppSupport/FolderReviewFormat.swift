import Foundation
import UniformTypeIdentifiers
import SnapsiftFolder

/// Presentation facts only; member types never change the primary's Core rank.
public struct FolderReviewFormat: Equatable, Sendable {
    public let label: String?
    public let includesRAW: Bool
    public let includesProcessed: Bool

    public init(primaryType: UTType?, memberTypes: [UTType]) {
        let images = (memberTypes + [primaryType].compactMap { $0 }).filter { $0.conforms(to: .image) }
        includesRAW = images.contains { $0.conforms(to: .rawImage) }
        includesProcessed = images.contains { !$0.conforms(to: .rawImage) }
        let processed = Set(images.filter { !$0.conforms(to: .rawImage) }.compactMap(Self.processedLabel))
        var labels: [String] = []
        if let primaryType, !primaryType.conforms(to: .rawImage),
           let primaryLabel = Self.processedLabel(primaryType), processed.contains(primaryLabel) {
            labels.append(primaryLabel)
        }
        labels += processed.sorted().filter { !labels.contains($0) }
        if includesRAW { labels.append("RAW") }
        label = labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    private static func processedLabel(_ type: UTType) -> String? {
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .heic) { return "HEIC" }
        if type.identifier == "public.heif" { return "HEIF" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .tiff) { return "TIFF" }
        return type.preferredFilenameExtension?.uppercased()
    }
}

/// Match the folder enumerator's member UTType lookup without reading files.
public func folderReviewFormat(for item: FolderItem) -> FolderReviewFormat {
    FolderReviewFormat(primaryType: UTType(filenameExtension: item.primary.url.pathExtension),
                      memberTypes: item.members.compactMap { UTType(filenameExtension: $0.url.pathExtension) })
}

/// A paired item alone is not a mixed group: the two formats must occur on
/// separate items before suggesting that one may be an export worth keeping.
public func folderGroupHasMixedFormats(_ formats: [FolderReviewFormat]) -> Bool {
    var seenRAW = false
    var seenProcessed = false
    for format in formats {
        if (format.includesRAW && seenProcessed) || (format.includesProcessed && seenRAW) { return true }
        seenRAW = seenRAW || format.includesRAW
        seenProcessed = seenProcessed || format.includesProcessed
    }
    return false
}
