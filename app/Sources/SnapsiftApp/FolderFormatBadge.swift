import SwiftUI
import SnapsiftAppSupport
import Signet

struct FolderFormatBadge: View {
    let format: FolderReviewFormat
    let t: L10n

    var body: some View {
        Text(t.folderFormatLabel(format))
            .font(.subheadline.weight(.bold))
            .lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(Color.reefGround)
            .padding(.horizontal, 7).padding(.vertical, CVERSpacing.xs)
            .background(format.includesRAW ? Color.reefAmber : Color.reefText,
                        in: RoundedRectangle(cornerRadius: CVERRadius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CVERRadius.chip, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .help(format.includesRAW && format.includesProcessed
                  ? t.folderRAWIncluded() : t.folderFormatAccessibility(t.folderFormatLabel(format)))
            .accessibilityLabel(t.folderFormatAccessibility(t.folderFormatLabel(format)))
    }
}
