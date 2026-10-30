# LiveKit Swift client SDK, vendored from github.com/livekit/client-sdk-swift at tag 2.19.0 (commit 43c1c0870e51eedbfd95b20b1b5c43a767886786).
# License: Apache-2.0, in LICENSE and NOTICE next to this file. Sources/CLiveKitProto and Sources/LiveKitNanopb contain the nanopb 0.4.9.2 runtime
# (github.com/nanopb/nanopb, tag 0.4.9.2, zlib license), see Sources/CLiveKitProto/LICENSE-nanopb.txt.
# Sources/LiveKit/Broadcast/NOTICE credits react-native-webrtc (MIT).
# LiveKitFFI is the Swift wrapper of github.com/livekit/livekit-ffi-xcframework at tag 0.13.1 (commit 685cfd95e23edf734450125eb58bb3bb21b4133b),
# license Apache-2.0, in LiveKitFFI/LICENSE. It imports the binary RustLiveKitFFI from //third-party/livekit.
# Vendored from the SwiftPM targets of the LiveKit package. The module.modulemap files of CLiveKitProto and LKObjCHelpers are not vendored,
# Bazel generates the modules from module_name. Not vendored: Tests, LiveKit.docc, protocol, scripts, podspec and the Package files.
# The WebRTC framework comes from //third-party/livekit:LiveKitWebRTC, not from the vendored third-party/webrtc tree.

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@rules_cc//cc:objc_library.bzl", "objc_library")

objc_library(
    name = "CLiveKitProto",
    srcs = glob([
        "Sources/CLiveKitProto/*.c",
    ]),
    hdrs = glob([
        "Sources/CLiveKitProto/include/**/*.h",
    ]),
    enable_modules = True,
    includes = [
        "Sources/CLiveKitProto/include",
    ],
    module_name = "CLiveKitProto",
    visibility = [
        "//visibility:public",
    ],
)

objc_library(
    name = "LKObjCHelpers",
    srcs = [
        "Sources/LKObjCHelpers/LKObjCHelpers.m",
    ],
    hdrs = [
        "Sources/LKObjCHelpers/include/LKObjCHelpers.h",
    ],
    enable_modules = True,
    includes = [
        "Sources/LKObjCHelpers/include",
    ],
    module_name = "LKObjCHelpers",
    sdk_frameworks = [
        "Foundation",
        "ReplayKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LiveKitNanopb",
    srcs = glob([
        "Sources/LiveKitNanopb/*.swift",
    ]),
    copts = [
        "-swift-version",
        "6",
        "-suppress-warnings",
        # LiveKitNanopb and LiveKit declare package-access members across the module boundary, so both need the same package name.
        "-package-name",
        "LiveKit",
    ],
    module_name = "LiveKitNanopb",
    deps = [
        ":CLiveKitProto",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LiveKitFFI",
    srcs = [
        "LiveKitFFI/livekit_common.swift",
        "LiveKitFFI/livekit_datatrack.swift",
        "LiveKitFFI/livekit_ffi.swift",
        "LiveKitFFI/livekit_net.swift",
    ],
    copts = [
        "-swift-version",
        "5",
        "-suppress-warnings",
    ],
    module_name = "LiveKitFFI",
    deps = [
        "//third-party/livekit:RustLiveKitFFI",
    ],
    visibility = [
        "//visibility:public",
    ],
)

swift_library(
    name = "LiveKit",
    srcs = glob([
        "Sources/LiveKit/**/*.swift",
    ]),
    # The resource Sources/LiveKit/PrivacyInfo.xcprivacy is vendored but not part of this build: no resource rule processes it.
    copts = [
        "-swift-version",
        "6",
        "-package-name",
        "LiveKit",
        "-suppress-warnings",
    ],
    module_name = "LiveKit",
    deps = [
        ":CLiveKitProto",
        ":LKObjCHelpers",
        ":LiveKitFFI",
        ":LiveKitNanopb",
        "//third-party/livekit:LiveKitWebRTC",
    ],
    visibility = [
        "//visibility:public",
    ],
)
