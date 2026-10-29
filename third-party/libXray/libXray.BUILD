load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_static_xcframework_import",
)

# Built into the external repository @libxray_apple from the XTLS/libXray release archive (see MODULE.bazel).
# Only the iOS device and simulator slices are imported. The macOS and tvOS slices in the archive are not used.
apple_static_xcframework_import(
    name = "LibXray",
    xcframework_imports = glob([
        "LibXray.xcframework/Info.plist",
        "LibXray.xcframework/ios-arm64/**",
        "LibXray.xcframework/ios-arm64_x86_64-simulator/**",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
