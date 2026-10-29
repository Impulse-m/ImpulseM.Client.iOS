import Foundation
import LiveKit


/// The media operations of the local participant in a LiveKit room. Call contexts use this seam instead of the SDK room, so they can be tested with fakes and no network.
public protocol LiveKitRoomMedia: AnyObject {
    /// Enables or disables the microphone. Disabling mutes it; the publication stays in the room.
    func setMicrophoneEnabled(_ isEnabled: Bool) async throws

    /// Turns the noise suppression of the microphone on or off.
    func setNoiseSuppressionEnabled(_ isEnabled: Bool) async throws

    /// Enables or disables the camera. Disabling mutes it; the publication stays in the room.
    func setCameraEnabled(_ isEnabled: Bool) async throws

    /// Publishes the camera track the call capturer owns. A camera publication that already exists is replaced, so only one camera is published.
    func publishCamera(_ track: LiveKitLocalVideoTrack) async throws

    /// Publishes the screen share track. Screen share audio is never published.
    func publishScreenShare(_ track: LiveKitLocalVideoTrack) async throws

    /// Removes the screen share publication from the room.
    func unpublishScreenShare() async throws

    /// Selects the audio input device with the identifier of `AudioDevice.id`. An identifier that no device owns changes nothing.
    func setAudioInputDevice(id: String) async throws

    /// Selects the audio output device with the identifier of `AudioDevice.id`. An identifier that no device owns changes nothing.
    func setAudioOutputDevice(id: String) async throws
}


/// A local video track that can be published to a room. Tests use a fake that has no SDK track.
public protocol LiveKitLocalVideoTrack: AnyObject {
    /// The SDK track behind this value, or nil when the value is not backed by one.
    var sdkTrack: LocalVideoTrack? { get }
}
