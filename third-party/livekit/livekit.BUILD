load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_dynamic_xcframework_import",
)

# Build file shared by the two external repositories declared in MODULE.bazel (@livekit_webrtc_apple, @livekit_ffi_apple).
# Each repository holds one xcframework, so the glob of the other target is empty there.
# The public labels are the aliases in third-party/livekit/BUILD.
#
# Pins (LiveKit client-sdk-swift 2.19.0, the macOS pin; the archives are the ones its Package.swift resolves):
#   livekit_webrtc_apple: webrtc-xcframework 150.7871.04
#     https://github.com/livekit/webrtc-xcframework/releases/download/150.7871.04/LiveKitWebRTC.xcframework.zip
#     sha256 3b0aa4bee8d5596d6592b8d75bddc84391769849fd64c04b8e13c9e77ce6a82b
#   livekit_ffi_apple: livekit-ffi-xcframework 0.13.1
#     https://github.com/livekit/livekit-uniffi-xcframework/releases/download/0.13.1/RustLiveKitFFI.xcframework.zip
#     sha256 9c6fca694df24f1206897c5787c001120c27e03a2b28688af76c83ea79a45805
#
# The WebRTC framework is the LK-prefixed copy. It does not replace the vendored third-party/webrtc tree that tgcalls uses.

apple_dynamic_xcframework_import(
    name = "LiveKitWebRTC",
    xcframework_imports = glob(
        ["LiveKitWebRTC.xcframework/**"],
        allow_empty = True,
    ),
    visibility = [
        "//visibility:public",
    ],
)

# The binary framework of the uniffi FFI, module RustLiveKitFFI. The Swift wrapper module LiveKitFFI is built from
# third-party/livekit-swift/LiveKitFFI and imports it.
apple_dynamic_xcframework_import(
    name = "RustLiveKitFFI",
    xcframework_imports = glob(
        ["RustLiveKitFFI.xcframework/**"],
        allow_empty = True,
    ),
    visibility = [
        "//visibility:public",
    ],
)
