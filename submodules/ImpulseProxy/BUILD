load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ImpulseProxy",
    module_name = "ImpulseProxy",
    srcs = glob([
        "Sources/ImpulseProxy/**/*.swift",
    ]),
    # The Go runtime inside libXray resolves DNS through libresolv (res_9_ninit, res_9_nsearch, res_9_nclose).
    linkopts = [
        "-lresolv",
    ],
    deps = [
        "//third-party/libXray:LibXray",
    ],
    visibility = [
        "//visibility:public",
    ],
)
