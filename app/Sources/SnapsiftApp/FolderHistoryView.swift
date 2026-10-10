import SwiftUI
import SnapsiftFolder
import SnapsiftAppSupport
import Signet

struct FolderHistoryView: View {
    @ObservedObject var model: FolderLibraryModel
    let t: L10n
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(t.folderHistory()).font(.title3.bold()).foregroundStyle(Color.reefMint)
                Spacer()
                Button(t.folderHistoryRefresh()) { model.refreshHistory(t) }.disabled(model.isBusy)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help(t.historyClose()).accessibilityLabel(t.historyClose())
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
            .padding(CVERSpacing.lg)
            Divider()
            if let recovery = model.recoveryMessage {
                Text(recovery).font(.callout).foregroundStyle(Color.reefAmber).padding(CVERSpacing.md)
            }
            if let problem = model.historyReadError {
                Text(problem).font(.callout).foregroundStyle(Color.reefAmber).padding(CVERSpacing.md)
            }
            if model.historyEntries.isEmpty {
                Text(model.historyReadError == nil ? t.folderHistoryEmpty() : t.folderHistory())
                    .foregroundStyle(Color.reefTextDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.historyEntries) { entry in entryRow(entry) }
                    }
                    .padding(CVERSpacing.lg)
                }
            }
            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small); Text(t.folderPuttingBack()) }
                else if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Color.reefGreen) }
                Spacer()
                Button(t.historyClose(), action: onClose).buttonStyle(.borderedProminent).tint(.reefTeal).disabled(model.isBusy)
            }
            .padding(CVERSpacing.lg)
        }
        .desktopSheetFrame(minWidth: 560, minHeight: 400, maxWidth: 760, maxHeight: 760)
        .background(Color.reefGround).preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isBusy)
        .alert(t.folderOperationReportTitle(), isPresented: Binding(
            get: { model.operationReport != nil }, set: { if !$0 { model.operationReport = nil } }
        )) {
            Button(t.deleteErrorDismiss(), role: .cancel) { model.operationReport = nil }
        } message: { Text(model.operationReport ?? "") }
    }

    private func entryRow(_ entry: FolderHistoryEntry) -> some View {
        let record = entry.record
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayDate(record.timestamp)).font(.callout.bold())
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.members.reduce(0) { $0 + $1.size }), countStyle: .file))
                    Text("\(t.historyReasonLabel()) \(t.historyReasonName(record.reason))")
                }
                Spacer()
                Button(t.folderPutBack()) { Task { await model.putBack(entry, t) } }
                    .buttonStyle(.bordered).disabled(!entry.putBackAvailable || model.isBusy || model.isScanning)
            }
            ForEach(Array(record.members.enumerated()), id: \.offset) { _, member in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(t.folderOriginalPath()): \(member.originalURL.path)")
                    if member.restored { Text(t.folderMemberRestored()).foregroundStyle(Color.reefGreen) }
                    if let trash = member.trashURL { Text("\(t.folderTrashLocation()): \(trash.path)") }
                    else { Text(t.folderHistoryUnavailable(.locationUnknown)).foregroundStyle(Color.reefAmber) }
                }
                .textSelection(.enabled)
            }
            if !entry.putBackAvailable {
                Text(t.folderHistoryUnavailable(folderHistoryUnavailableReason(record))).foregroundStyle(Color.reefAmber)
            }
        }
        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        .padding(CVERSpacing.md)
        .background(Color.reefDeep, in: RoundedRectangle(cornerRadius: CVERRadius.control))
        .overlay(RoundedRectangle(cornerRadius: CVERRadius.control).strokeBorder(Color.reefBorder, lineWidth: 1))
    }

    private func displayDate(_ timestamp: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else { return timestamp }
        let formatter = DateFormatter()
        formatter.locale = t.language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
