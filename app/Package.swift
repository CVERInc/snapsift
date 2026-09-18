// swift-tools-version: 5.9
import PackageDescription

// The native side of snapsift. SnapsiftCore is pure, dependency-free logic
// (clustering, keeper ranking, dHash) ported 1:1 from the Python reference and
// covered by the same cases. Tests are a framework-free executable runner
// (`swift run SnapsiftTests`) so they work under CommandLineTools without Xcode,
// matching the clioil/reepub family convention. The App and CLI targets layer
// PhotoKit / Vision on top of Core in later phases.
let package = Package(
    name: "snapsift",
    // iOS declared for the future iPhone target (thin Xcode project consuming
    // these same targets); SnapsiftIcon's body is macOS-fenced accordingly.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SnapsiftCore", targets: ["SnapsiftCore"]),
        .executable(name: "SnapsiftApp", targets: ["SnapsiftApp"]),
        .executable(name: "SnapsiftTests", targets: ["SnapsiftTests"]),
    ],
    dependencies: [
        // Signet — CVER's shared design system (palette, tokens, glass surfaces, chrome).
        // Pinned to main / latest per the in-house dep convention.
        .package(url: "https://github.com/CVERInc/signet", branch: "main"),
        // Sparkle 2 — auto-update framework for the sold-direct signed binary
        // (source builds have no feed URL / public key and simply never see an
        // update). Pinned to an exact release tag, unlike the in-house deps
        // above: it is third-party and macOS-only (its own Package.swift
        // declares only .macOS(.v12)), so it is attached to SnapsiftApp alone
        // via a macOS platform condition below, not to the package's
        // `dependencies` list as a whole.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "SnapsiftCore"),
        // SwiftUI app over the same engine: PhotoKit enumeration + thumbnails +
        // native deletion, with the reef family theme (now from CVERKit).
        // SwiftUI app: PhotoKit's escaping, non-Sendable callbacks fit the
        // tools-5.9 default (Swift 5) language mode cleanly.
        .executableTarget(name: "SnapsiftApp", dependencies: [
            "SnapsiftCore",
            .product(name: "Signet", package: "signet"),
            // macOS-only: `platforms` above also declares iOS 17 for the future
            // iPhone target, and Sparkle has no iOS build. All call sites are
            // additionally guarded with #if os(macOS).
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ]),
        .executableTarget(name: "SnapsiftTests", dependencies: ["SnapsiftCore"]),
        // Live-machine harness (`swift run SnapsiftLiveTests`): exercises the
        // REAL PhotoKit/Vision/sidecar paths against dedicated throwaway assets
        // it imports itself — never existing photos. Needs Photos permission
        // (TCC prompt on first run) and, for the delete step, a click on the
        // system confirmation. Complements SnapsiftTests, which stays pure.
        // The Info.plist is section-embedded into the Mach-O so TCC can attribute
        // the Photos prompt (a bare executable has no usage string → the request
        // hangs). MUST be run from a real Terminal for the prompt to surface.
        .executableTarget(name: "SnapsiftLiveTests", dependencies: ["SnapsiftCore"],
            exclude: ["Info.plist"],   // section-embedded via the linker, not a bundle resource
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/SnapsiftLiveTests/Info.plist",
            ])]),
        // Icon generator: `swift run SnapsiftIcon` → Assets/AppIcon.icns (+1024 PNG)
        // via Signet's shared CVERAppIcon pipeline. Run manually when the icon
        // artwork changes; the .icns is committed and bundled by build-app.sh.
        .executableTarget(name: "SnapsiftIcon", dependencies: [
            .product(name: "Signet", package: "signet"),
        ]),
    ]
)
