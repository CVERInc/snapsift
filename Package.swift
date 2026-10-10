// swift-tools-version: 5.9
import PackageDescription

// Public, dependency-free libraries shared by the macOS and iOS apps.
// The macOS executables and their dependencies belong to app/Package.swift.
let package = Package(
    name: "snapsift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SnapsiftCore", targets: ["SnapsiftCore"]),
        .library(name: "SnapsiftVision", targets: ["SnapsiftVision"]),
        .library(name: "SnapsiftPhotoKit", targets: ["SnapsiftPhotoKit"]),
    ],
    targets: [
        .target(name: "SnapsiftCore"),
        .target(name: "SnapsiftVision", dependencies: ["SnapsiftCore"]),
        .target(name: "SnapsiftPhotoKit", dependencies: ["SnapsiftCore", "SnapsiftVision"]),
    ]
)
