// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "ImpulseNetworkEngine",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImpulseNetworkEngine",
            targets: ["ImpulseNetworkEngine"]),
    ],
    dependencies: [
        .package(name: "TelegramCore", path: "../TelegramCore"),
        .package(name: "MtProtoKit", path: "../MtProtoKit"),
        .package(name: "SSignalKit", path: "../SSignalKit"),
        .package(name: "ImpulseTransport", path: "../ImpulseTransport"),
        .package(name: "EncryptionProvider", path: "../EncryptionProvider"),
    ],
    targets: [
        .target(
            name: "ImpulseNetworkEngine",
            dependencies: [
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "MtProtoKit", package: "MtProtoKit", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "ImpulseTransport", package: "ImpulseTransport", condition: nil),
            ],
            path: "Sources/ImpulseNetworkEngine"),
        .testTarget(
            name: "ImpulseNetworkEngineTests",
            dependencies: [
                "ImpulseNetworkEngine",
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "MtProtoKit", package: "MtProtoKit", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "EncryptionProvider", package: "EncryptionProvider", condition: nil),
                .product(name: "ImpulseTransport", package: "ImpulseTransport", condition: nil),
            ],
            path: "Tests/ImpulseNetworkEngineTests"),
    ]
)
