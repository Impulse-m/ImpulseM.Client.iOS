# Vendored from https://github.com/apple/swift-protobuf at tag 1.35.1, Sources/SwiftProtobuf and LICENSE.txt (Apache-2.0).

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SwiftProtobuf",
    module_name = "SwiftProtobuf",
    srcs = glob([
        "Sources/SwiftProtobuf/**/*.swift",
    ]),
    copts = [
        "-suppress-warnings",
        # The sources use the package access level, which SwiftPM names automatically.
        "-package-name",
        "SwiftProtobuf",
    ],
    deps = [
    ],
    visibility = [
        "//visibility:public",
    ],
)
