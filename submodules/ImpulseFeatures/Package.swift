// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "ImpulseFeatures",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "ImpulseFeatures",
            targets: ["ImpulseFeatures"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ImpulseFeatures",
            dependencies: [],
            path: "Sources/ImpulseFeatures"),
        .testTarget(
            name: "ImpulseFeaturesTests",
            dependencies: ["ImpulseFeatures"],
            path: "Tests/ImpulseFeaturesTests"),
    ]
)
