import SwiftUI
import SnapsiftCore
import SnapsiftFolder
import SnapsiftAppSupport
import Signet

struct FolderPreCommitReviewSheet: View {
    let payload: FolderRemovalReview
    let model: FolderLibraryModel
    let t: L10n
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var noSurvivorAcknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(t.folderReviewRemovalTitle(payload.summary.itemCount)).font(.title2.bold()).foregroundStyle(.white)
                Text(t.folderReviewRemovalSubtitle(payload.summary.totalBytes)).font(.callout).foregroundStyle(Color.reefTextDim)
            }
            .multilineTextAlignment(.center).padding(CVERSpacing.lg)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(t.folderReviewEligible(payload.summary.eligibleItemIDs.count)).font(.callout)
                    ForEach(payload.summary.volumes, id: \.volumeKey) { volume in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(volume.displayName).font(.callout.bold())
                            Text(t.folderVolumeTotal(volume.itemCount, bytes: volume.totalBytes)).font(.caption)
                            if case .scanOnly(let reason) = volume.capability {
                                Label(t.folderScanOnly(reason), systemImage: "lock.fill").foregroundStyle(Color.reefAmber)
                            } else if !volume.isStartupVolume {
                                Text(t.folderExternalTrashSpace()).foregroundStyle(Color.reefAmber)
                            }
                        }
                    }
                    if payload.protectedCount > 0 {
                        Label(t.folderProtectedWarning(payload.protectedCount), systemImage: "exclamationmark.lock.fill")
                            .font(.callout.bold()).foregroundStyle(Color.reefRed)
                    }
                    if !payload.summary.withdrawals.isEmpty {
                        Text(t.folderReviewWithdrawals()).font(.callout.bold())
                        ForEach(Array(payload.summary.withdrawals.enumerated()), id: \.offset) { _, withdrawal in
                            Text(t.folderWithdrawalReport(withdrawal.itemCount, reason: withdrawal.reason))
                                .foregroundStyle(Color.reefAmber)
                        }
                    }
                    if payload.noSurvivorCount > 0 {
                        Text(t.folderNoSurvivorWarning(payload.noSurvivorCount)).font(.callout.bold()).foregroundStyle(Color.reefAmber)
                        Toggle(t.folderNoSurvivorAcknowledge(), isOn: $noSurvivorAcknowledged).toggleStyle(.checkbox)
                    }
                    ForEach(payload.groups.filter(\.effectivelyArmed)) { group in groupRow(group) }
                }
                .font(.caption).padding(CVERSpacing.lg)
            }
            Divider()
            HStack {
                Button(t.preCommitCancel(), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(role: .destructive, action: onConfirm) { Text("\(t.folderMoveToTrash()) · ⌘⏎") }
                    .buttonStyle(.borderedProminent).tint(.reefRed)
                    .disabled(payload.summary.eligibleItemIDs.isEmpty || (payload.noSurvivorCount > 0 && !noSurvivorAcknowledged))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(CVERSpacing.lg)
        }
        .desktopSheetFrame(minWidth: 560, minHeight: 520, maxWidth: 700, maxHeight: 860)
        .background(Color.reefGround).preferredColorScheme(.dark)
    }

    private func groupRow(_ group: ReviewGroup) -> some View {
        let withdrawal = payload.summary.withdrawals.first { $0.groupID == group.id }
        return VStack(alignment: .leading, spacing: 8) {
            if let withdrawal {
                Label(t.folderWithdrawal(withdrawal.reason), systemImage: "minus.circle").foregroundStyle(Color.reefAmber)
            } else if let kept = group.photos.first(where: { group.isKeeper($0) }) {
                HStack(spacing: 10) {
                    model.reviewThumbnail(for: kept, box: CGSize(width: 64, height: 64))
                        .clipShape(RoundedRectangle(cornerRadius: CVERRadius.chip))
                        .overlay(RoundedRectangle(cornerRadius: CVERRadius.chip).strokeBorder(Color.reefGreen, lineWidth: 2))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.preCommitKept()).font(.caption.bold()).foregroundStyle(Color.reefGreen)
                        Text(kept.filename).lineLimit(1).truncationMode(.middle)
                        if let item = model.item(for: kept.uuid) { Text(item.primary.url.path).textSelection(.enabled) }
                    }
                }
            } else {
                Label(t.folderNoSurvivorRow(), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.reefAmber)
            }
            ForEach(group.photos.filter { group.isDelete($0) }) { photo in
                HStack(alignment: .top, spacing: 10) {
                    model.reviewThumbnail(for: photo, box: CGSize(width: 52, height: 52))
                        .opacity(0.34).clipShape(RoundedRectangle(cornerRadius: CVERRadius.chip))
                        .overlay(RoundedRectangle(cornerRadius: CVERRadius.chip)
                            .strokeBorder(photo.isProtected ? Color.reefAmber : Color.reefRed, lineWidth: 1.5))
                        .overlay { if photo.isProtected { Image(systemName: "lock.fill").foregroundStyle(Color.reefAmber) } }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(photo.filename).font(.caption.bold())
                        if let item = model.item(for: photo.uuid) {
                            ForEach(item.members, id: \.url) { Text($0.url.path).textSelection(.enabled) }
                        }
                        if photo.isProtected { Text(t.folderProtectedWarning(1)).foregroundStyle(Color.reefAmber) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(withdrawal == nil ? 1 : 0.6)
        .padding(CVERSpacing.md)
        .background(Color.reefDeep, in: RoundedRectangle(cornerRadius: CVERRadius.control))
        .overlay(RoundedRectangle(cornerRadius: CVERRadius.control).strokeBorder(Color.reefBorder, lineWidth: 1))
    }
}
