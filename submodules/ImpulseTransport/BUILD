load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ImpulseTransport",
    module_name = "ImpulseTransport",
    srcs = glob([
        "Sources/ImpulseTransport/**/*.swift",
    ]),
    data = glob([
        "Resources/**",
    ]),
    deps = [
        "//third-party/SwiftCentrifuge:SwiftCentrifuge",
        "//third-party/swift-protobuf:SwiftProtobuf",
    ],
    visibility = [
        "//visibility:public",
    ],
)
