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
    /// True while a scan / face pass is actually running — the only time ⌘.
    /// has anything to stop.
    var canCancelScan: Bool
    var scan: (LibraryModel.ScanKind) -> Void
    var refineFaces: () -> Void
    var writeAlbums: () -> Void
    var deleteMarked: () -> Void
    /// Stop the in-flight scan (⌘.). Never touches a photo — see SPEC §2:
    /// the ONLY key that changes data is ⌘⏎ inside the review sheet.
    var cancelScan: () -> Void
    var showHistory: () -> Void
    var toggleHelp: () -> Void
    /// Sparkle "Check for Updates…" (macOS only; see SnapsiftUpdateCommands
    /// below). ContentView forwards the App-owned updater through here rather
    /// than a second FocusedValue-style bridge. Always false/no-op on
    /// platforms without Sparkle linked.
    var canCheckForUpdates: Bool
    var checkForUpdates: () -> Void
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
            // ⌘. — registered here, like every other ⌘ shortcut, so the cheat
            // sheet and the binding cannot drift (designer item 14). It used to
            // live on the scan screen's own button and therefore existed only
            // while that view was on screen, and appeared in no documentation.
            Button(t.menuStopScan()) { actions?.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(actions?.canCancelScan != true)
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

/// Standard-placement "Check for Updates…" item (App menu, right after the
/// automatic "About snapsift" group — CommandGroupPlacement.appInfo is macOS's
/// documented spot for it, and is what Sparkle's own SwiftUI guidance uses).
/// Reuses the same `snapsiftActions` FocusedValue bridge as every other menu
/// item above rather than a second updater-specific mechanism; the updater
/// itself lives in SnapsiftApp.swift and is forwarded in by ContentView.
struct SnapsiftUpdateCommands: Commands {
    @FocusedValue(\.snapsiftActions) private var actions
    @AppStorage("snapsift.language") private var langRaw = Language.detect().rawValue
    private var t: L10n { L10n(Language(rawValue: langRaw) ?? .en) }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(t.checkForUpdates()) { actions?.checkForUpdates() }
                .disabled(actions?.canCheckForUpdates != true)
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
