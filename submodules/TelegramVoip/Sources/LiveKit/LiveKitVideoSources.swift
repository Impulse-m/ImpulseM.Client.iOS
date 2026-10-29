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
    public static func createCameraTrack(
        captureCode: LiveKitCaptureCode,
        deviceId: String
    ) -> LocalVideoTrack? {
        guard let position: AVCaptureDevice.Position = cameraPosition(captureCode: captureCode) else {
            return nil
        }
        let device: AVCaptureDevice? = deviceId.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceId)
        let options: CameraCaptureOptions = CameraCaptureOptions(
            device: device,
            position: position
        )
        return LocalVideoTrack.createCameraTrack(options: options)
    }


    /// Publish options for a video track of the call.
    ///
    /// Camera tracks use simulcast only in a group call. Screen share never uses simulcast.
    public static func videoPublishOptions(
        captureCode: LiveKitCaptureCode,
        isGroupCall: Bool
    ) -> VideoPublishOptions {
        let simulcast: Bool = isGroupCall && captureCode != .screen
        return VideoPublishOptions(simulcast: simulcast)
    }


    #if os(macOS)
    /// Creates the screen share track for a source chosen with `MacOSScreenCapturer.sources(for:)`. Screen share audio is never published.
    @available(macOS 12.3, *)
    public static func createMacOSScreenShareTrack(
        source: MacOSScreenCaptureSource
    ) -> LocalVideoTrack {
        return LocalVideoTrack.createMacOSScreenShareTrack(source: source)
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
