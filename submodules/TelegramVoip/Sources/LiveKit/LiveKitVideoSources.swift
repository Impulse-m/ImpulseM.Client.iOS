import AVFoundation
import Foundation
import LiveKit


/// Capture codes shared with the call engine. The raw values match the Android capture codes.
public enum LiveKitCaptureCode: Int32 {
    case back = 0
    case front = 1
    case screen = 2
}


/// Builds the local video tracks of a LiveKit call: the camera tracks and the macOS screen share track.
public enum LiveKitVideoSources {
    /// Creates a camera track for the back or front capture code. Returns nil for the screen code.
    ///
    /// The device identifier selects a specific camera on macOS. An empty identifier, or one that no device owns, falls back to the position.
    ///
    /// The track is created on the RTC executor, so the calling task suspends instead of blocking its thread.
    public static func createCameraTrack(
        captureCode: LiveKitCaptureCode,
        deviceId: String
    ) async -> LocalVideoTrack? {
        guard let position: AVCaptureDevice.Position = cameraPosition(captureCode: captureCode) else {
            return nil
        }
        let device: AVCaptureDevice? = deviceId.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceId)
        let options: CameraCaptureOptions = CameraCaptureOptions(
            device: device,
            position: position
        )
        return await LocalVideoTrack.createCameraTrack(options: options)
    }


    /// Publish options for a video track of the call.
    ///
    /// Camera tracks use simulcast only in a group call. Screen share never uses simulcast.
    /// The VP8 preference of the call maps to the preferred codec of the track; without it the SDK picks the codec.
    public static func videoPublishOptions(
        captureCode: LiveKitCaptureCode,
        isGroupCall: Bool,
        prioritizeVP8: Bool = false
    ) -> VideoPublishOptions {
        let simulcast: Bool = isGroupCall && captureCode != .screen
        let preferredCodec: VideoCodec? = prioritizeVP8 ? VideoCodec.vp8 : nil
        return VideoPublishOptions(
            simulcast: simulcast,
            preferredCodec: preferredCodec
        )
    }


    #if os(macOS)
    /// Creates the screen share track for a source chosen with `MacOSScreenCapturer.sources(for:)`. Screen share audio is never published.
    @available(macOS 12.3, *)
    public static func createMacOSScreenShareTrack(
        source: MacOSScreenCaptureSource
    ) async -> LocalVideoTrack {
        return await LocalVideoTrack.createMacOSScreenShareTrack(source: source)
    }
    #endif


    private static func cameraPosition(captureCode: LiveKitCaptureCode) -> AVCaptureDevice.Position? {
        switch captureCode {
        case .back:
            return .back
        case .front:
            return .front
        case .screen:
            return nil
        }
    }
}
