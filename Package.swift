// swift-tools-version: 6.2
//
// meshyy — a resumable, roaming-tolerant terminal transport.
// Copyright (c) 2026 Aaron Character. MIT licence — see LICENSE.
//
// DEPENDENCY POLICY: `dependencies:` is empty and must stay empty.
// See CLAUDE.md and docs/provenance.md (2026-07-27, zero dependencies).
// CI fails the build if anything is added here.

import PackageDescription

let package = Package(
    name: "meshyy",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        // Shared by both ends: wire format, framing, session model, resume.
        .library(name: "MeshyyCore", targets: ["MeshyyCore"]),
        // Client side. This is what a+Terminal links.
        .library(name: "MeshyyKit", targets: ["MeshyyKit"]),
        // Server side. macOS only.
        .library(name: "MeshyyDaemon", targets: ["MeshyyDaemon"]),
        .executable(name: "meshyyd", targets: ["meshyyd"]),
        .executable(name: "meshyy", targets: ["meshyy"]),
        // Test/benchmark support: latency, loss and hard-drop injection.
        .executable(name: "meshyy-chaos", targets: ["meshyy-chaos"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MeshyyCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MeshyyKit",
            dependencies: ["MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MeshyyDaemon",
            dependencies: ["MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "meshyyd",
            dependencies: ["MeshyyDaemon", "MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "meshyy",
            dependencies: ["MeshyyKit", "MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MeshyyChaos",
            dependencies: ["MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "meshyy-chaos",
            dependencies: ["MeshyyChaos"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeshyyCoreTests",
            dependencies: ["MeshyyCore", "MeshyyChaos"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeshyyDaemonTests",
            dependencies: ["MeshyyDaemon", "MeshyyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeshyyKitTests",
            // Depends on the daemon too: the M2 acceptance test drives a real
            // daemon over a real QUIC connection rather than a stub, because a
            // client tested against a stub only proves the two agree with
            // each other.
            dependencies: ["MeshyyKit", "MeshyyCore", "MeshyyDaemon"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
