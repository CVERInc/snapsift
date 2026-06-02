// swift-tools-version: 6.0
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
        .executable(name: "SnapsiftTests", targets: ["SnapsiftTests"]),
    ],
    targets: [
        .target(name: "SnapsiftCore"),
        .executableTarget(name: "SnapsiftTests", dependencies: ["SnapsiftCore"]),
    ]
)
