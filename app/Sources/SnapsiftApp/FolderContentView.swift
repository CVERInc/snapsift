import SwiftUI
import SnapsiftCore
import SnapsiftFolder
import Signet

struct FolderContentView: View {
    @ObservedObject var model: FolderLibraryModel
    let t: L10n
    let requestScan: () -> Void
    @State private var contentWidth: CGFloat = 0
    @State private var removeTarget: UUID?
    @State private var showDiscard = false
    @State private var forceTarget: String?
    @State private var hint: String?
    @FocusState private var gridFocused: Bool

    private var selectedGroup: ReviewGroup? { model.groups.first { $0.id == model.selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section(t.folderChosen()) {
                    ForEach(model.folders) { folder in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.url?.lastPathComponent ?? t.folderUnavailable())
                                if let url = folder.url {
                                    Text(url.path).font(.caption).foregroundStyle(Color.reefTextDim)
                                }
                                if folder.wasStale {
                                    Label(t.folderBookmarkStale(), systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(Color.reefAmber)
                                }
                                if folder.unavailable {
                                    Text(t.folderUnavailable()).font(.caption).foregroundStyle(Color.reefAmber)
                                }
                            }
                            Spacer()
                            Button {
                                if model.userMarkCount > 0 { removeTarget = folder.id }
                                else { model.removeFolder(folder.id, t) }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help(t.folderRemove())
                            .accessibilityLabel(t.folderRemove())
                            .disabled(model.isScanning)
                        }
                    }
                    Button(t.folderChoose()) { model.chooseFolders(t) }.disabled(model.isScanning)
                }
                Section(t.folderReviewTitle()) {
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.photos.first?.filename ?? t.folderReviewTitle())
                                .lineLimit(1).truncationMode(.middle)
                            Text(t.folderReviewCounts(count: group.photos.count, marked: group.deletionIDs.count))
                                .font(.caption).foregroundStyle(Color.reefTextDim)
                            if group.photos.contains(where: { model.crossFolderItemIDs.contains($0.uuid) }) {
                                Label(t.folderCrossDuplicates(), systemImage: "folder.badge.questionmark")
                                    .font(.caption).foregroundStyle(Color.reefAmber)
                            } else if model.result?.exactGroupIDs.contains(group.id) == true {
                                Text(t.exactDupeBadge()).font(.caption).foregroundStyle(Color.reefTeal)
                            }
                        }
                        .tag(group.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.reefDeep.opacity(0.55))
            .frame(minWidth: 240)
        } detail: {
            VStack(spacing: 0) {
                if let result = model.result { volumeStatus(result) }
                if let group = selectedGroup {
                    GroupReview(group: group, model: model, t: t, contentWidth: $contentWidth,
                                focusedFrame: model.focusedFrame,
                                isExactDupeGroup: model.result?.exactGroupIDs.contains(group.id) == true,
                                sectionTitle: t.folderReviewTitle(),
                                onDesktopTap: { id in
                                    model.focusedFrame = id
                                    model.promote(group: group.id, to: id)
                                    gridFocused = true
                                })
                    .focusable().focused($gridFocused)
                    .onKeyPress { key in handleKey(key, group) }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.largeTitle).foregroundStyle(Color.reefMint)
                        Text(model.hasScanned ? t.folderNoGroups() : t.folderStart())
                            .multilineTextAlignment(.center).foregroundStyle(Color.reefTextDim)
                        Button(t.folderChoose()) { model.chooseFolders(t) }.disabled(model.isScanning)
                    }
                    .padding(CVERSpacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 460)
            .background(Color.reefGround)
        }
        .navigationTitle(t.folderMode())
        .toolbar {
            ToolbarItem {
                Button(t.scan(), action: requestScan).disabled(!model.canScan)
            }
            ToolbarItem {
                Button(t.folderMoveToTrash()) {}.disabled(true).help(t.folderComing())
            }
            ToolbarItem {
                Button(t.folderHistory()) {}.disabled(true).help(t.folderComing())
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .onAppear { model.loadFolders(t) }
        .onChange(of: model.selection) { _, id in
            let group = model.groups.first(where: { $0.id == id })
            if !(group?.photos.contains { $0.uuid == model.focusedFrame } ?? false) {
                model.focusedFrame = group?.keeperID
            }
            hint = nil
        }
        .alert(t.folderErrorTitle(), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(t.deleteErrorDismiss(), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(t.folderDiscard(), isPresented: Binding(
            get: { removeTarget != nil || showDiscard },
            set: { if !$0 { removeTarget = nil; showDiscard = false } }
        ), titleVisibility: .visible) {
            Button(t.folderDiscard(), role: .destructive) {
                if let id = removeTarget { model.removeFolder(id, t) }
                else { model.discardResult() }
                removeTarget = nil
                showDiscard = false
            }
            Button(t.rescanDiscardCancel(), role: .cancel) { removeTarget = nil; showDiscard = false }
        } message: { Text(t.folderDiscardBody(model.userMarkCount)) }
        .alert(t.folderProtectedTitle(), isPresented: Binding(
            get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }
        )) {
            Button(t.folderMarkAnyway(), role: .destructive) {
                if let group = selectedGroup, let id = forceTarget { model.forceReject(group: group.id, frameID: id) }
                forceTarget = nil
            }
            Button(t.deleteProtectedAlertCancel(), role: .cancel) { forceTarget = nil }
        } message: { Text(t.folderProtectedBody(1)) }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isScanning {
                HStack {
                    // The current pipeline exposes no stage/count callback;
                    // use Photos Mode's indeterminate-progress convention.
                    ProgressView().controlSize(.small)
                    Text(t.folderScanning())
                    Spacer()
                    Button(t.menuStopScan()) { model.cancelScan() }
                }
            } else if let notice = model.notice {
                Text(notice)
            }
            if let hint { Text(hint).foregroundStyle(Color.reefAmber) }
            HStack {
                Text(t.folderComing()).foregroundStyle(Color.reefTextDim)
                Spacer()
                Button(t.folderDiscard()) {
                    if model.userMarkCount > 0 { showDiscard = true }
                    else { model.discardResult() }
                }.disabled(model.result == nil || model.isScanning)
            }
        }
        .font(.callout).padding(CVERSpacing.md)
        .background(Color.reefDeep)
    }

    private func volumeStatus(_ result: FolderScanResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(result.roots.enumerated()), id: \.offset) { _, root in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(root.volume.displayName ?? t.folderVolumeUnknown()) · \(root.url.path)")
                            .font(.callout.weight(.semibold)).textSelection(.enabled)
                        switch root.volume.capability {
                        case .removalSupported:
                            Text(t.folderVolumeSupported()).foregroundStyle(Color.reefTextDim)
                        case .scanOnly(let reason):
                            Label(t.folderScanOnly(reason), systemImage: "lock.fill").foregroundStyle(Color.reefAmber)
                        }
                    }
                }
                if !result.crossFolderDuplicates.isEmpty {
                    Text(t.folderCrossExplanation()).foregroundStyle(Color.reefAmber)
                    ForEach(Array(result.crossFolderDuplicates.enumerated()), id: \.offset) { _, duplicate in
                        ForEach(duplicate.itemIDs, id: \.self) { id in
                            if let item = result.items.first(where: { $0.id == id }) {
                                Button(item.primary.url.path) {
                                    model.selection = model.groups.first { $0.photos.contains { $0.uuid == id } }?.id
                                    model.focusedFrame = id
                                    gridFocused = true
                                }
                                .buttonStyle(.plain).foregroundStyle(Color.reefMint)
                            }
                        }
                        Divider()
                    }
                }
                if !result.issues.isEmpty {
                    Text(t.folderSkipped(result.issues.count)).foregroundStyle(Color.reefAmber)
                    ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.url.path) · \(t.folderIssue(issue.reason))")
                    }
                }
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(CVERSpacing.md)
        }
        .frame(maxHeight: 160)
        .background(Color.reefDeep.opacity(0.6))
    }

    private func handleKey(_ key: KeyPress, _ group: ReviewGroup) -> KeyPress.Result {
        guard !model.isScanning, !key.modifiers.contains(.command), !key.modifiers.contains(.control),
              let id = model.focusedFrame, let index = group.photos.firstIndex(where: { $0.uuid == id }) else { return .ignored }
        switch key.key {
        case .leftArrow, .rightArrow:
            let next = index + (key.key == .leftArrow ? -1 : 1)
            if group.photos.indices.contains(next) { model.focusedFrame = group.photos[next].uuid }
        case .upArrow, .downArrow:
            let spacing = Double(GroupReview<FolderLibraryModel>.gallerySpacing)
            let rows = JustifiedLayout.rows(aspectRatios: group.photos.map { model.displayAspect(for: $0) },
                                            containerWidth: Double(contentWidth),
                                            targetHeight: JustifiedLayout.targetHeight(forWidth: Double(contentWidth)),
                                            spacing: spacing)
            if let next = JustifiedLayout.rowNeighbor(rows: rows, spacing: spacing, from: index,
                                                      delta: key.key == .upArrow ? -1 : 1) {
                model.focusedFrame = group.photos[next].uuid
            }
        case "k", "K":
            if key.modifiers.contains(.shift) { model.keepOnly(group: group.id, frame: id) }
            else { model.promote(group: group.id, to: id) }
        case "a", "A": model.keepAll(group: group.id)
        case "d", "D": model.toggleDeleteAll(group: group.id)
        case "x", "X", .delete:
            let photo = group.photos[index]
            if key.modifiers.contains(.shift), photo.isProtected, !photo.isUnverifiable, !group.rejected.contains(id) {
                forceTarget = id
            } else if !model.toggleReject(group: group.id, frameID: id) {
                hint = photo.isUnverifiable ? t.folderUnverifiable() : t.protectedHint()
            }
        default:
            guard let number = Int(key.characters), (1...9).contains(number), group.photos.indices.contains(number - 1) else {
                return .ignored
            }
            let frame = group.photos[number - 1].uuid
            model.promote(group: group.id, to: frame)
            model.focusedFrame = frame
        }
        return .handled
    }
}
