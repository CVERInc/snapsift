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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapsiftCore", targets: ["SnapsiftCore"]),
        .executable(name: "SnapsiftApp", targets: ["SnapsiftApp"]),
        .executable(name: "SnapsiftTests", targets: ["SnapsiftTests"]),
    ],
    targets: [
        .target(name: "SnapsiftCore"),
        // SwiftUI app over the same engine: PhotoKit enumeration + thumbnails +
        // native deletion, with the reef family theme.
        // SwiftUI app: PhotoKit's escaping, non-Sendable callbacks fit the
        // tools-5.9 default (Swift 5) language mode cleanly.
        .executableTarget(name: "SnapsiftApp", dependencies: ["SnapsiftCore"]),
        .executableTarget(name: "SnapsiftTests", dependencies: ["SnapsiftCore"]),
    ]
)
