load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ImpulseNetworkEngine",
    module_name = "ImpulseNetworkEngine",
    srcs = glob([
        "Sources/ImpulseNetworkEngine/**/*.swift",
    ]),
    deps = [
        "//submodules/ImpulseTransport",
        "//submodules/MtProtoKit:MtProtoKit",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//third-party/SwiftCentrifuge:SwiftCentrifuge",
    ],
    visibility = [
        "//visibility:public",
    ],
)
