// swift-tools-version: 5.9

import PackageDescription

// The Foundation-only half of the iOS collector (the native contract): the
// normalizer (MetricKit diagnostic JSON in, a bounded record out), the store
// (state, seen-set, inbox, run records) and the collector that serializes
// them on one queue. The plugin adds only MetricKit and the Flutter channels.
// No MetricKit, no UIKit, no CryptoKit, so `swift test` runs on macOS and on
// a Linux toolchain alike.
//
// It lives inside the plugin package's directory on purpose: Flutter links a
// plugin's Swift package into the app through a symlink, and Swift Package
// Manager resolves a sibling path (`../…`) from that symlink, where no sibling
// exists. A nested path resolves through the symlink.
let package = Package(
    name: "NativeCrashNormalizer",
    platforms: [
        .iOS("15.0"),
        .macOS("12.0"),
    ],
    products: [
        .library(name: "NativeCrashNormalizer", targets: ["NativeCrashNormalizer"])
    ],
    targets: [
        .target(name: "NativeCrashNormalizer"),
        .testTarget(
            name: "NativeCrashNormalizerTests",
            dependencies: ["NativeCrashNormalizer"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
