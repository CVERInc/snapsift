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
    /// Whether the updater can actually run a check RIGHT NOW. Not a constant:
    /// when Sparkle's startup validation fails (no public key, or no feed to
    /// check — every source build), `canCheckForUpdates` is false and the menu
    /// item must be disabled. Hard-coding `true` left a "Check for Updates…"
    /// item that was clickable and did nothing.
    var checkAvailable: Bool = false
    var check: () -> Void = {}
}

#if os(macOS)
/// Republishes Sparkle's KVO-observable `canCheckForUpdates` as SwiftUI state,
/// so the menu item's `.disabled` re-evaluates when the updater's readiness
/// changes (it starts false and flips once the updater has validated itself, or
/// stays false forever in a build with no feed). This is the shape Sparkle's own
/// SwiftUI guidance uses; a one-shot read at scene-construction time would be
/// captured before the answer exists.
final class SnapsiftUpdaterState: ObservableObject {
    @Published var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?
    init(_ updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] u, _ in
            let value = u.canCheckForUpdates
            // Swift 5.10 (CI, macos-14) rejects a captured `self` inside the
            // Task; bind it to a `let` first, as saveSnapshotIgnoringScanState does.
            let state = self
            Task { @MainActor in state?.canCheckForUpdates = value }
        }
    }
}
#endif
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
    // docs/UPDATES.md).
    //
    // Source checkouts and CI builds have NEITHER SUPublicEDKey NOR SUFeedURL:
    // `build-app.sh` writes the feed URL only alongside a public key, precisely
    // so this sentence is true. With no feed there is nothing to fetch, so such
    // a build makes no update request at all and this updater simply reports
    // `canCheckForUpdates == false` — which is what disables the menu item
    // below. (An earlier version wrote SUFeedURL unconditionally; the updater
    // then had a feed and no key, and depending on how Sparkle judged the
    // ad-hoc signature either failed startup with a modal alert one second
    // after launch or scheduled real background checks against oss.cver.net.)
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var updaterState: SnapsiftUpdaterState

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        updaterController = controller
        _updaterState = StateObject(wrappedValue: SnapsiftUpdaterState(controller.updater))
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup("snapsift") {
            ContentView()
                .cverTheme(ReefTheme())
                .environment(\.snapsiftUpdateChecker, SnapsiftUpdateChecker(
                    checkAvailable: updaterState.canCheckForUpdates,
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
