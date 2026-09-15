import SwiftUI

/// Bridge between the window's ContentView (which owns the model and all
/// action state) and the menu-bar Commands scene. ContentView publishes this
/// via `.focusedSceneValue`; the menus read it with `@FocusedValue` — nil when
/// no snapsift window is key, which disables every item automatically.
struct SnapsiftActions {
    var canScan: Bool
    var canRefineFaces: Bool
    var canWriteAlbums: Bool
    var canDelete: Bool
    var scan: (LibraryModel.ScanKind) -> Void
    var refineFaces: () -> Void
    var writeAlbums: () -> Void
    var deleteMarked: () -> Void
    var showHistory: () -> Void
    var toggleHelp: () -> Void
}

private struct SnapsiftActionsKey: FocusedValueKey {
    typealias Value = SnapsiftActions
}

extension FocusedValues {
    var snapsiftActions: SnapsiftActions? {
        get { self[SnapsiftActionsKey.self] }
        set { self[SnapsiftActionsKey.self] = newValue }
    }
}

/// The app's menu bar: every primary action lives in a named menu (macOS
/// convention, shortcut discovery, and the standard VoiceOver / Full Keyboard
/// Access fallback). The ⌘-shortcuts are registered HERE — not on toolbar
/// buttons — so each exists exactly once and the menu stays their single
/// source of truth. Item enablement mirrors the toolbar's disabled logic via
/// the bridged `can…` flags; the model-level guards (startScan/deleteReviewed)
/// remain the final authority either way.
struct SnapsiftMenuCommands: Commands {
    @FocusedValue(\.snapsiftActions) private var actions
    @AppStorage("snapsift.language") private var langRaw = Language.detect().rawValue
    private var t: L10n { L10n(Language(rawValue: langRaw) ?? .en) }

    var body: some Commands {
        CommandMenu(t.menuActions()) {
            Button(t.scan()) { actions?.scan(.burst) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions?.canScan != true)
            Button(t.lookAlikes()) { actions?.scan(.lookAlikes) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions?.canScan != true)
            Button(t.similarSets()) { actions?.scan(.similarSets) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(actions?.canScan != true)
            Divider()
            Button(t.faces(false)) { actions?.refineFaces() }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(actions?.canRefineFaces != true)
            Button(t.sortIntoAlbums()) { actions?.writeAlbums() }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(actions?.canWriteAlbums != true)
            Divider()
            Button(t.menuDeleteMarked()) { actions?.deleteMarked() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canDelete != true)
            Divider()
            Button(t.historyTitle()) { actions?.showHistory() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(actions == nil)
            Button(t.helpTitle()) { actions?.toggleHelp() }
                .keyboardShortcut("?", modifiers: .command)
                .disabled(actions == nil)
        }
    }
}

/// ⌘, settings: the language picker (the toolbar globe stays for
/// discoverability — both write the same @AppStorage key).
struct SnapsiftSettingsView: View {
    @AppStorage("snapsift.language") private var langRaw = Language.detect().rawValue
    private var t: L10n { L10n(Language(rawValue: langRaw) ?? .en) }

    var body: some View {
        Form {
            Picker(t.settingsLanguage(), selection: $langRaw) {
                ForEach(Language.allCases) { l in Text(l.endonym).tag(l.rawValue) }
            }
            .pickerStyle(.inline)
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}
