import SwiftUI
import AppKit
import SnapsiftCore

// MARK: - History view

/// Feature 4: in-app "Removed" history sheet.
///
/// Lists past delete sessions newest-first. Each session shows:
///   - timestamp + photo count
///   - "In Recently Deleted — recoverable until <date>"
///   - Per-photo rows: filename, keeper, reason
///
/// Footer: "Export Log…" → NSSavePanel → write .txt or .jsonl to a user location.
struct DeletionHistoryView: View {
    let t: L10n
    let onClose: () -> Void

    @State private var sessions: [DeletionSession] = []
    @State private var exporting = false

    private let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(t.historyTitle())
                    .font(.title3.bold())
                    .foregroundStyle(Color.reefMint)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.reefTextDim)
                }
                .buttonStyle(.plain)
                .help(t.historyClose())
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color.reefBorder)

            if sessions.isEmpty {
                Spacer()
                Text(t.historyEmpty())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.reefTextDim)
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(sessions.indices, id: \.self) { idx in
                            sessionRow(sessions[idx])
                        }
                    }
                    .padding(16)
                }
            }

            Divider().background(Color.reefBorder)

            HStack {
                Spacer()
                Button(t.historyExportLog()) { exportLog() }
                    .buttonStyle(.bordered)
                    .disabled(sessions.isEmpty || exporting)
                Button(t.historyClose()) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(.reefTeal)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 520, minHeight: 360, maxHeight: 600)
        .background(Color.reefGround)
        .preferredColorScheme(.dark)
        .onAppear { sessions = DeletionAuditLog.loadSessions() }
    }

    // MARK: - Session row

    private func sessionRow(_ session: DeletionSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            let date = isoDate(session.timestamp)
            Text(t.historySessionHeader(date: date, count: session.records.count))
                .font(.callout.bold())
                .foregroundStyle(.white)

            // Recovery window
            if let until = session.recoverableUntil {
                let untilStr = displayFmt.string(from: until)
                let expired = until < Date()
                Text(expired ? t.historyExpired() : t.historyRecoverable(until: untilStr))
                    .font(.caption)
                    .foregroundStyle(expired ? Color.reefTextDim : Color.reefGreen)
            }

            // Per-photo rows (capped at 6 for brevity; user can export for full list)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(session.records.prefix(6).indices, id: \.self) { i in
                    let r = session.records[i]
                    let name = r.filename.isEmpty ? String(r.assetIdentifier.prefix(12)) : r.filename
                    HStack(alignment: .top, spacing: 4) {
                        Text("·")
                            .foregroundStyle(Color.reefTextDim)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.reefText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                Text("\(t.historyKeeperLabel()) \(r.keeperFilename.isEmpty ? r.keeperIdentifier : r.keeperFilename)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.reefTextDim)
                                Text("\(t.historyReasonLabel()) \(r.reason.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.reefTextDim)
                            }
                        }
                    }
                }
                if session.records.count > 6 {
                    Text(t.historyMore(session.records.count - 6))
                        .font(.caption2)
                        .foregroundStyle(Color.reefTextDim)
                        .padding(.top, 2)
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.reefDeep, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.reefBorder, lineWidth: 1)
        )
    }

    // MARK: - Export

    private func exportLog() {
        exporting = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(t.historyExportFilename()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = t.historyTitle()
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { response in
            defer { exporting = false }
            guard response == .OK, let url = panel.url else { return }
            let text = DeletionAuditLog.exportText(sessions: sessions)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private let isoFmt = ISO8601DateFormatter()
    private func isoDate(_ ts: String) -> String {
        guard let d = isoFmt.date(from: ts) else { return ts }
        return displayFmt.string(from: d)
    }
}
