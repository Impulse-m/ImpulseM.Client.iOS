# SwiftCentrifuge, copied from the Impulse-m/ImpulseM.Centrifugo.Client.Swift repository at tag v2.0.0.
# The license is in LICENSE next to this file (MIT).

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SwiftCentrifuge",
    module_name = "SwiftCentrifuge",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-swift-version",
        "5",
    ],
    deps = [
        "//third-party/swift-protobuf:SwiftProtobuf",
    ],
    visibility = [
        "//visibility:public",
    ],
)
