import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SnapsiftAppSupport
import SnapsiftFolder

private enum FolderReviewFormatTestError: Error { case imageWrite }

private func writeReviewFormatJPEG(at url: URL) throws {
    guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                 bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                             UTType.jpeg.identifier as CFString,
                                                             1, nil) else {
        throw FolderReviewFormatTestError.imageWrite
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FolderReviewFormatTestError.imageWrite }
}

func folderReviewFormatTests(_ check: (Bool, String) -> Void) {
    print("Folder review file formats")
    let jpeg = FolderReviewFormat(primaryType: .jpeg, memberTypes: [.jpeg])
    let heic = FolderReviewFormat(primaryType: .heic, memberTypes: [.heic])
    let png = FolderReviewFormat(primaryType: .png, memberTypes: [.png])
    let tiff = FolderReviewFormat(primaryType: .tiff, memberTypes: [.tiff])
    let dngType = UTType(filenameExtension: "dng")!
    let canonType = UTType(filenameExtension: "cr2")!
    let dng = FolderReviewFormat(primaryType: dngType, memberTypes: [dngType])
    let canon = FolderReviewFormat(primaryType: canonType, memberTypes: [canonType])
    let pair = FolderReviewFormat(primaryType: .jpeg, memberTypes: [dngType, .jpeg])
    let heicPair = FolderReviewFormat(primaryType: .heic, memberTypes: [.heic, canonType])
    let unknown = FolderReviewFormat(primaryType: .image, memberTypes: [.image])

    check(jpeg.label == "JPEG" && jpeg.includesProcessed && !jpeg.includesRAW, "JPEG is a processed format")
    check(heic.label == "HEIC" && heic.includesProcessed && !heic.includesRAW, "HEIC is a processed format")
    check(png.label == "PNG" && png.includesProcessed && !png.includesRAW, "PNG is a processed format")
    check(tiff.label == "TIFF" && tiff.includesProcessed && !tiff.includesRAW, "TIFF is a processed format")
    check(dng.label == "RAW" && dng.includesRAW && !dng.includesProcessed, "DNG is RAW, including when it conforms to TIFF")
    check(canon.label == "RAW" && canon.includesRAW && !canon.includesProcessed, "camera RAW other than DNG is RAW")
    check(pair.label == "JPEG + RAW" && pair.includesRAW && pair.includesProcessed,
          "RAW companion is visible alongside its processed JPEG primary")
    check(heicPair.label == "HEIC + RAW" && heicPair.includesRAW, "HEIC primary includes its camera RAW companion")
    check(FolderReviewFormat(primaryType: .jpeg, memberTypes: [.jpeg, dngType]).label == pair.label,
          "RAW pair label is independent of member order")
    check(FolderReviewFormat(primaryType: .jpeg, memberTypes: [.jpeg, .jpeg, dngType, canonType]).label == "JPEG + RAW",
          "repeated format members do not repeat labels")
    check(FolderReviewFormat(primaryType: .heic, memberTypes: [.jpeg, dngType, .heic]).label == "HEIC + JPEG + RAW",
          "processed primary comes first and RAW stays visible in a multi-format item")
    check(FolderReviewFormat(primaryType: .jpeg, memberTypes: [.jpeg, .quickTimeMovie]).label == "JPEG",
          "Live Photo movie companion is excluded from image format labels")
    check(FolderReviewFormat(primaryType: .jpeg, memberTypes: [.jpeg, .data]).label == "JPEG",
          "sidecar data does not become a processed image format")
    check(FolderReviewFormat(primaryType: nil, memberTypes: [dngType, .jpeg]).label == "JPEG + RAW",
          "member types supply a label when the primary type is unavailable")
    check(FolderReviewFormat(primaryType: UTType(filenameExtension: "JPG"), memberTypes: [.jpeg]).label == "JPEG",
          "uppercase JPG member extension resolves to the JPEG label")
    check(FolderReviewFormat(primaryType: .gif, memberTypes: [.gif]).label == "GIF", "other known images use their UTType format name")
    check(unknown.label == nil && unknown.includesProcessed && !unknown.includesRAW, "generic image type uses a localized fallback")
    check(FolderReviewFormat(primaryType: nil, memberTypes: []).label == nil, "missing member types use a localized fallback")

    do {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapsift-review-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("RAW fixture".utf8).write(to: root.appendingPathComponent("PAIR.dng"))
        try writeReviewFormatJPEG(at: root.appendingPathComponent("PAIR.jpg"))
        try writeReviewFormatJPEG(at: root.appendingPathComponent("single.jpg"))
        let enumeration = try FolderEnumerator.enumerate(root: root)
        let pairItem = enumeration.items.first { $0.primary.url.lastPathComponent.lowercased() == "pair.jpg" }
        let singleItem = enumeration.items.first { $0.primary.url.lastPathComponent.lowercased() == "single.jpg" }
        let pairFormat = pairItem.map { folderReviewFormat(for: $0) }
        let singleFormat = singleItem.map { folderReviewFormat(for: $0) }
        check(enumeration.issues.isEmpty && enumeration.items.count == 2 && pairItem?.members.count == 2
              && pairFormat?.label == "JPEG + RAW" && pairFormat?.includesRAW == true
              && pairFormat?.includesProcessed == true && singleFormat?.label == "JPEG"
              && singleFormat?.includesProcessed == true && singleFormat?.includesRAW == false,
              "real folder items resolve JPEG and DNG formats from filename extensions")
    } catch {
        check(false, "real folder items resolve JPEG and DNG formats from filename extensions")
    }

    check(folderGroupHasMixedFormats([dng, jpeg]), "separate RAW and JPEG items show the mixed-format notice")
    check(folderGroupHasMixedFormats([jpeg, canon]), "mixed-group detection is independent of item order and RAW subtype")
    check(folderGroupHasMixedFormats([dng, heic]), "separate RAW and HEIC items show the mixed-format notice")
    check(!folderGroupHasMixedFormats([pair]), "one RAW+JPEG item alone is not a mixed group")
    check(!folderGroupHasMixedFormats([pair, pair]), "two RAW+JPEG pair items do not show the mixed-format notice")
    check(!folderGroupHasMixedFormats([pair, heicPair]), "RAW+JPEG and RAW+HEIC pair items do not show the mixed-format notice")
    check(!folderGroupHasMixedFormats([jpeg, jpeg]), "all-JPEG group has no mixed-format notice")
    check(!folderGroupHasMixedFormats([jpeg, heic, png, tiff]), "processed formats alone have no RAW export notice")
    check(!folderGroupHasMixedFormats([dng, canon]), "all-RAW group has no mixed-format notice")
    check(!folderGroupHasMixedFormats([]), "empty group has no mixed-format notice")
    check(folderGroupHasMixedFormats([pair, jpeg]), "a RAW companion and a separate processed item can trigger the notice")
    check(folderGroupHasMixedFormats([dng, pair]), "a processed primary and a separate RAW item can trigger the notice")

    for language in Language.allCases {
        let t = L10n(language)
        check([jpeg, heic, png, tiff, dng, canon, pair, heicPair, unknown].allSatisfy { !t.folderFormatLabel($0).isEmpty },
              "folder format labels and fallback exist in \(language.rawValue)")
        check(t.folderFormatLabel(pair) == "JPEG + RAW" && t.folderFormatLabel(dng) == "RAW",
              "format acronyms and RAW inclusion stay legible in \(language.rawValue)")
        check(t.folderFormatAccessibility("JPEG + RAW").contains("JPEG + RAW"),
              "format accessibility message includes the item's formats in \(language.rawValue)")
        check(!t.folderRAWIncluded().isEmpty && !t.folderMixedFormats().isEmpty,
              "RAW companion explanation and mixed-group notice exist in \(language.rawValue)")
    }
    check(Set(Language.allCases.map { L10n($0).folderFormatLabel(unknown) }).count == 3,
          "unknown image label is translated for every language")
    check(Set(Language.allCases.map { L10n($0).folderFormatAccessibility("RAW") }).count == 3,
          "format accessibility prefix is translated for every language")
    check(Set(Language.allCases.map { L10n($0).folderRAWIncluded() }).count == 3,
          "RAW inclusion explanation is translated for every language")
    check(Set(Language.allCases.map { L10n($0).folderMixedFormats() }).count == 3,
          "mixed-format notice is translated for every language")
    check(L10n(.zhTW).folderRAWIncluded().contains("垃圾桶") && L10n(.zhTW).folderRAWIncluded().contains("放回原處")
          && L10n(.zhTW).folderMixedFormats().contains("匯出"), "RAW and export copy uses Taiwan wording")
}
