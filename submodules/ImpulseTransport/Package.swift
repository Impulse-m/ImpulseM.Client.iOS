// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "ImpulseTransport",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "ImpulseTransport",
            targets: [
                "ImpulseTransport",
            ]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/Impulse-m/ImpulseM.Centrifugo.Client.Swift.git",
            from: "2.0.2"
        ),
    ],
    targets: [
        .target(
            name: "ImpulseTransport",
            dependencies: [
                .product(
                    name: "SwiftCentrifuge",
                    package: "impulsem.centrifugo.client.swift"
                ),
            ],
            path: ".",
            exclude: [
                "Tests",
            ],
            sources: [
                "Sources/ImpulseTransport",
            ],
            resources: [
                .copy("Resources/tl-proto-232.json"),
            ]
        ),
        .testTarget(
            name: "ImpulseTransportTests",
            dependencies: [
                "ImpulseTransport",
            ],
            path: "Tests/ImpulseTransportTests"
        ),
    ]
)
