// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TelegramVoip",
    platforms: [.macOS(.v12), .iOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "TelegramVoip",
            targets: ["TelegramVoip"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(name: "TgVoipWebrtc", path: "../../../tgcalls"),
        .package(name: "SSignalKit", path: "../SSignalKit"),
        .package(name: "FFMpegBinding", path: "../FFMpegBinding"),
        .package(name: "TelegramCore", path: "../TelegramCore"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.19.0"),

    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "TelegramVoip",
            dependencies: [
                .product(name: "TgVoipWebrtc", package: "TgVoipWebrtc", condition: nil),
                .product(name: "SwiftSignalKit", package: "SSignalKit", condition: nil),
                .product(name: "FFMpegBinding", package: "FFMpegBinding", condition: nil),
                .product(name: "TelegramCore", package: "TelegramCore", condition: nil),
                .product(name: "LiveKit", package: "client-sdk-swift", condition: nil),
            ],
            path: "Sources",
            exclude: [
                "IpcGroupCallContext.swift",
                "OngoingCallContext.swift",
            ],
            cxxSettings: [
                .define("WEBRTC_MAC", to: "1", nil),
            ]),
        .testTarget(
            name: "TelegramVoipTests",
            dependencies: ["TelegramVoip"],
            path: "Tests"
        ),
    ]
)
