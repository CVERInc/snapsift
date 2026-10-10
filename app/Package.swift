// swift-tools-version: 5.9
import PackageDescription

// The macOS app and its executable tools consume the shared root libraries.
// Tests are a framework-free executable runner
// (`swift run SnapsiftTests`) so they work under CommandLineTools without Xcode,
// matching the clioil/reepub family convention.
let package = Package(
    name: "app",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SnapsiftApp", targets: ["SnapsiftApp"]),
        .executable(name: "SnapsiftTests", targets: ["SnapsiftTests"]),
    ],
    dependencies: [
        // Explicit name binds product references independently of the checkout
        // directory's SwiftPM identity (including differently named worktrees).
        .package(name: "snapsift", path: ".."),
        // Signet — CVER's shared design system (palette, tokens, glass surfaces, chrome).
        // Pinned to main / latest per the in-house dep convention.
        .package(url: "https://github.com/CVERInc/signet", branch: "main"),
        // Sparkle 2 — auto-update framework for the sold-direct signed binary
        // (source builds have no feed URL / public key and simply never see an
        // update). Pinned to an exact release tag, unlike the in-house deps
        // above: it is third-party and macOS-only (its own Package.swift
        // declares only .macOS(.v12)), so it is attached to SnapsiftApp alone,
        // never to the root libraries.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // SwiftUI app over the same engine: PhotoKit enumeration + thumbnails +
        // native deletion, with Signet's shared theme.
        // SwiftUI app: PhotoKit's escaping, non-Sendable callbacks fit the
        // tools-5.9 default (Swift 5) language mode cleanly.
        .executableTarget(name: "SnapsiftApp", dependencies: [
            .product(name: "SnapsiftCore", package: "snapsift"),
            .product(name: "SnapsiftPhotoKit", package: "snapsift"),
            .product(name: "Signet", package: "signet"),
            // Sparkle and its call sites are macOS-only.
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ]),
        .executableTarget(name: "SnapsiftTests", dependencies: [
            .product(name: "SnapsiftCore", package: "snapsift"),
            .product(name: "SnapsiftFolder", package: "snapsift"),
        ]),
        // Live-machine harness (`swift run SnapsiftLiveTests`): exercises the
        // REAL PhotoKit/Vision/sidecar paths against dedicated throwaway assets
        // it imports itself — never existing photos. Needs Photos permission
        // (TCC prompt on first run) and, for the delete step, a click on the
        // system confirmation. Complements SnapsiftTests, which stays pure.
        // The Info.plist is section-embedded into the Mach-O so TCC can attribute
        // the Photos prompt (a bare executable has no usage string → the request
        // hangs). MUST be run from a real Terminal for the prompt to surface.
        .executableTarget(name: "SnapsiftLiveTests", dependencies: [
            .product(name: "SnapsiftCore", package: "snapsift"),
        ],
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
