import SwiftUI
import Photos
import SnapsiftCore
import Signet

// MARK: - Pre-commit data

/// Snapshot of one group's pending deletion, computed before the sheet is shown.
struct PreCommitGroup: Identifiable {
    let id: ReviewGroup.ID
    let keeper: Photo
    let keeperReason: KeeperReason
    let toRemove: [Photo]
    let includeProtected: Bool
}

// MARK: - Pre-commit review sheet

/// Feature 1: the "are you sure?" sheet that shows EXACTLY what will happen
/// before `deleteReviewed()` calls PHPhotoLibrary delete.
///
/// Header: "Move N photos to Recently Deleted? · ≈X MB freed · recoverable for 30 days."
/// Body:   scrollable list per group — surviving keeper + why + dimmed frames being removed.
/// Footer: Confirm → real delete. Cancel → abort.
///
/// Integrates the existing protected-include confirmation: if any protected
/// frames are force-included, a red warning row replaces the separate dialog.
/// The user only sees ONE prompt, not two stacked dialogs.
struct PreCommitReviewSheet: View {
    let groups: [PreCommitGroup]
    let totalDeletions: Int
    let reclaimableBytes: Int
    let totalProtected: Int   // total protected frames across all groups being deleted
    let noSurvivorCount: Int  // groups where every frame goes to Recently Deleted
    let model: LibraryModel
    let t: L10n
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var noSurvivorAcknowledged = false

    private var confirmEnabled: Bool {
        noSurvivorCount == 0 || noSurvivorAcknowledged
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            VStack(spacing: 4) {
                Text(t.preCommitTitle(totalDeletions))
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(t.preCommitSubtitle(bytes: reclaimableBytes))
                    .font(.callout)
                    .foregroundStyle(Color.reefTextDim)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider().background(Color.reefBorder)

            // MARK: Protected warning (integrates existing confirm dialog)
            if totalProtected > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.lock.fill")
                        .foregroundStyle(.red)
                    Text(t.preCommitProtectedWarning(totalProtected))
                        .font(.callout.bold())
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))

                Divider().background(Color.reefBorder)
            }

            // MARK: No-survivor warning + checkbox
            if noSurvivorCount > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t.preCommitNoSurvivorWarning(noSurvivorCount))
                        .font(.callout.bold())
                        .foregroundStyle(Color.reefAmber)
                        .multilineTextAlignment(.leading)
                    Toggle(isOn: $noSurvivorAcknowledged) {
                        Text(t.preCommitNoSurvivorAcknowledge())
                            .font(.callout)
                            .foregroundStyle(Color.reefText)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.reefAmber.opacity(0.08))

                Divider().background(Color.reefBorder)
            }

            // MARK: Scrollable group list
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups) { g in
                        GroupPreCommitRow(group: g, model: model, t: t)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 420)

            Divider().background(Color.reefBorder)

            // MARK: Footer buttons
            HStack(spacing: 12) {
                Button(t.preCommitCancel()) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) { onConfirm() }
                    label: { Text(t.preCommitConfirm()) }
                    .buttonStyle(.borderedProminent)
                    .tint(.reefRed)
                    .disabled(!confirmEnabled)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, maxWidth: 700)
        .background(Color.reefGround)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Per-group row in the sheet

private struct GroupPreCommitRow: View {
    let group: PreCommitGroup
    let model: LibraryModel
    let t: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Keeper row
            HStack(spacing: 10) {
                // Keeper thumbnail (not dimmed)
                AssetThumbnail(asset: model.asset(for: group.keeper.uuid),
                               manager: model.imageManager,
                               box: CGSize(width: 64, height: 64),
                               quarterTurns: model.rotation(for: group.keeper.uuid),
                               fill: true)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.reefGreen, lineWidth: 2)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(t.preCommitKept())
                            .font(.caption.bold())
                            .foregroundStyle(Color.reefGreen)
                        Text(group.keeper.filename.isEmpty
                             ? String(group.keeper.uuid.prefix(8))
                             : group.keeper.filename)
                            .font(.caption)
                            .foregroundStyle(Color.reefText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(keeperWhyLabel(group.keeperReason))
                        .font(.caption2)
                        .foregroundStyle(Color.reefTextDim)
                }

                Spacer()
            }

            // Removing thumbnails (dimmed)
            if !group.toRemove.isEmpty {
                HStack(spacing: 6) {
                    Text(t.preCommitRemoving())
                        .font(.caption.bold())
                        .foregroundStyle(Color.reefTextDim)
                        .frame(width: 62, alignment: .leading)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(group.toRemove) { p in
                                ZStack {
                                    AssetThumbnail(asset: model.asset(for: p.uuid),
                                                   manager: model.imageManager,
                                                   box: CGSize(width: 52, height: 52),
                                                   quarterTurns: model.rotation(for: p.uuid),
                                                   fill: true)
                                        .opacity(0.34)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(
                                                    p.isProtected ? Color.reefAmber : Color.reefRed,
                                                    lineWidth: 1.5
                                                )
                                        )
                                    if p.isProtected {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(Color.reefAmber)
                                    }
                                }
                                .frame(width: 52, height: 52)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.reefDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.reefBorder, lineWidth: 1)
        )
    }

    private func keeperWhyLabel(_ reason: KeeperReason) -> String {
        switch reason {
        case .favorite:       return t.keeperWhyFavorite()
        case .quality:        return t.keeperWhyQuality()
        case .originalCamera: return t.keeperWhyOriginalCamera()
        case .sharpness:      return t.keeperWhySharpness()
        case .format:         return t.keeperWhyFormat()
        case .size:           return t.keeperWhySize()
        case .earliest:       return t.keeperWhyEarliest()
        }
    }
}
