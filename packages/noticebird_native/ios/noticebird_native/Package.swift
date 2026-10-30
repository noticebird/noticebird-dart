// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "noticebird_native",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "noticebird-native", targets: ["noticebird_native"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Nested rather than a sibling: Flutter links this package through a
        // symlink, and a sibling path would resolve beside the symlink.
        .package(name: "NativeCrashNormalizer", path: "NativeCrashNormalizer"),
    ],
    targets: [
        .target(
            name: "noticebird_native",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "NativeCrashNormalizer", package: "NativeCrashNormalizer"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("MetricKit")
            ]
        )
    ]
)
