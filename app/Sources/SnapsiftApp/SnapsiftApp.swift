import SwiftUI
import Signet
#if os(macOS)
import Sparkle
#endif

// Native surface over SnapsiftCore — reef-styled (deep teal, mint, teal accent).
// Palette/tokens/components now come from Signet (the shared design system);
// snapsift uses the default ReefTheme. Scan your Photos library for
// near-duplicate bursts, review each cluster, and delete the extras straight
// into Recently Deleted.

/// Forwards the App-owned Sparkle updater into ContentView's existing
/// SnapsiftActions/focusedSceneValue bridge (see Commands.swift) instead of a
/// second, updater-specific bridge. A plain struct (not the SPUUpdater type
/// itself) so ContentView.swift and Commands.swift need not import Sparkle;
/// the default — unavailable, no-op — is what every non-macOS build sees,
/// since only the macOS `WindowGroup` below ever overrides it.
struct SnapsiftUpdateChecker {
    var checkAvailable: Bool = false
    var check: () -> Void = {}
}
private struct SnapsiftUpdateCheckerKey: EnvironmentKey {
    static let defaultValue = SnapsiftUpdateChecker()
}
extension EnvironmentValues {
    var snapsiftUpdateChecker: SnapsiftUpdateChecker {
        get { self[SnapsiftUpdateCheckerKey.self] }
        set { self[SnapsiftUpdateCheckerKey.self] = newValue }
    }
}

@main
struct SnapsiftApp: App {
    #if os(macOS)
    // Sparkle 2 updater, owned by the App (not a view) so it outlives any
    // window opening/closing. `startingUpdater: true` makes it perform
    // Sparkle's own default background check-on-launch — no extra nag on top
    // of that, and nothing beyond a version/OS check is ever sent (see
    // docs/UPDATES.md). Source checkouts and CI builds simply have no
    // SUFeedURL/SUPublicEDKey (build-app.sh omits them when the env vars
    // aren't set), so this updater has nothing to check against and stays
    // silent — no separate "am I the official binary" branch needed here.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup("snapsift") {
            ContentView()
                .cverTheme(ReefTheme())
                .environment(\.snapsiftUpdateChecker, SnapsiftUpdateChecker(
                    checkAvailable: true,
                    check: { updaterController.updater.checkForUpdates() }))
        }
        .windowResizability(.contentSize)   // macOS-only modifier
        .commands {
            SnapsiftMenuCommands()
            SnapsiftUpdateCommands()
        }
        Settings {
            SnapsiftSettingsView()
                .cverTheme(ReefTheme())
                .preferredColorScheme(.dark)
        }
        #else
        WindowGroup("snapsift") {
            ContentView()
                .cverTheme(ReefTheme())
        }
        #endif
    }
}
