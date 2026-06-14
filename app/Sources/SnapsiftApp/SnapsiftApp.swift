import SwiftUI
import Signet

// Native surface over SnapsiftCore — reef-styled (deep teal, mint, teal accent).
// Palette/tokens/components now come from Signet (the shared design system);
// snapsift uses the default ReefTheme. Scan your Photos library for
// near-duplicate bursts, review each cluster, and delete the extras straight
// into Recently Deleted.

@main
struct SnapsiftApp: App {
    var body: some Scene {
        WindowGroup("snapsift") {
            ContentView()
                .cverTheme(ReefTheme())
        }
        .windowResizability(.contentSize)
    }
}
