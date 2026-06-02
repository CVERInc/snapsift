import SwiftUI

// Native surface over SnapsiftCore — reef-styled (deep teal, mint, teal accent).
// Scan your Photos library for near-duplicate bursts, review each cluster, and
// delete the extras straight into Recently Deleted.

@main
struct SnapsiftApp: App {
    var body: some Scene {
        WindowGroup("snapsift") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
