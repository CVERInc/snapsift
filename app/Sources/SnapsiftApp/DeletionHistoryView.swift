import SwiftUI
import UniformTypeIdentifiers
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
    // Built once on demand (not on every body render) so the O(history) export
    // string isn't rebuilt when the sheet merely re-renders.
    @State private var exportDoc: PlainTextDocument?
    // The export is a user-initiated write: a silent failure (full disk, denied
    // volume) is indistinguishable from success, so surface both outcomes.
    @State private var exportError: String?
    @State private var exportSaved = false

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
                .accessibilityLabel(t.historyClose())
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
                if exportSaved {
                    Label(t.historyExportSaved(), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.reefGreen)
                }
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
        .desktopSheetFrame(minWidth: 520, minHeight: 360, maxHeight: 600)
        .background(Color.reefGround)
        .preferredColorScheme(.dark)
        // Parse the log off the main thread — it reads and JSON-decodes the whole
        // deletions.jsonl, which grows to thousands of records at dogfood scale.
        .task {
            sessions = await Task.detached(priority: .userInitiated) {
                DeletionAuditLog.loadSessions()
            }.value
        }
        .fileExporter(isPresented: $exporting,
                      document: exportDoc,
                      contentType: .plainText,
                      defaultFilename: t.historyExportFilename()) { result in
            // fileExporter's completion does not fire on cancel, so the failure
            // alert can't false-trigger.
            if case .failure(let err) = result {
                exportError = err.localizedDescription
            } else {
                exportSaved = true
            }
        }
        .alert(t.historyExportFailedTitle(), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(t.deleteErrorDismiss(), role: .cancel) { exportError = nil }
        } message: {
            if let exportError { Text(exportError) }
        }
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
                HStack(spacing: 8) {
                    Text(expired ? t.historyExpired() : t.historyRecoverable(until: untilStr))
                        .font(.caption)
                        .foregroundStyle(expired ? Color.reefTextDim : Color.reefGreen)
                    // "recoverable until <date>" is otherwise a dead end — give it
                    // a path to Photos, where Recently Deleted lives in the sidebar.
                    if !expired {
                        Button(t.historyOpenPhotos()) { openPhotos() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(Color.reefMint)
                    }
                }
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
                                Text("\(t.historyKeeperLabel()) \(r.keeperFilename.isEmpty && r.keeperIdentifier.isEmpty ? t.historyNoSurvivor() : (r.keeperFilename.isEmpty ? r.keeperIdentifier : r.keeperFilename))")
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

    /// Platform-neutral export: SwiftUI's fileExporter replaces NSSavePanel
    /// (identical UX on macOS, and it just works on iOS).
    /// Open the Photos app so the user can reach Recently Deleted. Bundle-ID
    /// lookup is more robust than the photos:// scheme; macOS has no documented
    /// deep link to the Recently Deleted album specifically, so Photos itself is
    /// the closest actionable target.
    private func openPhotos() {
        #if os(macOS)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        #else
        if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
        #endif
    }

    private func exportLog() {
        exportSaved = false
        // Build the export string once, here, instead of on every body render.
        exportDoc = PlainTextDocument(text: DeletionAuditLog.exportText(sessions: sessions))
        exporting = true
    }

    // MARK: - Helpers

    /// Minimal FileDocument wrapper so the audit log exports through SwiftUI's
    /// platform-neutral fileExporter.
    struct PlainTextDocument: FileDocument {
        static var readableContentTypes: [UTType] { [.plainText] }
        var text: String
        init(text: String) { self.text = text }
        init(configuration: ReadConfiguration) throws {
            text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
        }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: Data(text.utf8))
        }
    }

    private let isoFmt = ISO8601DateFormatter()
    private func isoDate(_ ts: String) -> String {
        guard let d = isoFmt.date(from: ts) else { return ts }
        return displayFmt.string(from: d)
    }
}
