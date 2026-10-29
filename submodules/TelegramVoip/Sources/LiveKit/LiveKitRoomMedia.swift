import Foundation
import LiveKit


/// The media operations of the local participant in a LiveKit room. Call contexts use this seam instead of the SDK room, so they can be tested with fakes and no network.
public protocol LiveKitRoomMedia: AnyObject {
    /// Called on the main actor when an audio track of the room becomes available: a remote track once it is subscribed, and the local microphone once it is published. Each track is reported once.
    var onAudioTrackAvailable: ((LiveKitAudioTrackHandle) -> Void)? { get set }

    /// Called on the main actor once when an audio track that was reported goes away.
    var onAudioTrackRemoved: ((LiveKitAudioTrackHandle) -> Void)? { get set }

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


/// An audio track of a room that a level meter can read. No SDK type appears in this surface, so tests use a fake.
public protocol LiveKitAudioTrackHandle: AnyObject, Sendable {
    /// The identity of the participant that owns the track. The local microphone carries the identity of the local participant.
    var participantIdentity: String { get }

    /// True for the local microphone and false for a remote track.
    var isLocal: Bool { get }

    /// Attaches the meter, so that it receives the buffers of the track. Attaching a meter that is already attached has no effect.
    func attachMeter(_ meter: LiveKitAudioLevelMeter)

    /// Detaches the meter. A meter that is not attached has no effect.
    func detachMeter(_ meter: LiveKitAudioLevelMeter)

    /// Sets the playout gain of a remote track, from 0 (muted) to 10 (unity gain is 1). The local microphone ignores it.
    /// The value is applied asynchronously and in the order of the calls.
    func setPlaybackVolume(_ volume: Double)
}


/// Remembers the audio tracks of a room by key, so that each track is reported once when it appears and once when it goes away.
/// The registry is not thread-safe. Its owner locks around every call.
final class LiveKitAudioTrackRegistry {
    private var handles: [String: LiveKitAudioTrackHandle] = [:]


    /// Returns the handle made for a key that is not registered yet, and nil when the key is already registered.
    func register(key: String, makeHandle: () -> LiveKitAudioTrackHandle) -> LiveKitAudioTrackHandle? {
        if handles[key] != nil {
            return nil
        }
        let handle: LiveKitAudioTrackHandle = makeHandle()
        handles[key] = handle
        return handle
    }


    /// Forgets the key and returns the handle registered under it, or nil when the key is not registered.
    func unregister(key: String) -> LiveKitAudioTrackHandle? {
        return handles.removeValue(forKey: key)
    }
}


/// Carries the audio track events of one room from the LiveKit threads to the main actor. Each track is reported once when it appears and once when it goes away.
final class LiveKitAudioTrackHub: @unchecked Sendable {
    /// Called on the main actor when an audio track becomes available. Set it before the room connects.
    var availableHandler: ((LiveKitAudioTrackHandle) -> Void)? {
        get {
            return withLock {
                return availableStorage
            }
        }
        set {
            withLock {
                availableStorage = newValue
            }
        }
    }


    /// Called on the main actor once when an audio track that was reported goes away. Set it before the room connects.
    var removedHandler: ((LiveKitAudioTrackHandle) -> Void)? {
        get {
            return withLock {
                return removedStorage
            }
        }
        set {
            withLock {
                removedStorage = newValue
            }
        }
    }


    private let lock: NSLock = NSLock()
    private var registry: LiveKitAudioTrackRegistry = LiveKitAudioTrackRegistry()
    private var availableStorage: ((LiveKitAudioTrackHandle) -> Void)?
    private var removedStorage: ((LiveKitAudioTrackHandle) -> Void)?


    /// Reports a track that appeared. Called on any thread. A key that is already registered is ignored, and `makeHandle` runs only for a new key.
    func trackDidAppear(key: String, makeHandle: () -> LiveKitAudioTrackHandle) {
        let handle: LiveKitAudioTrackHandle? = withLock {
            return registry.register(key: key, makeHandle: makeHandle)
        }
        guard let handle: LiveKitAudioTrackHandle = handle else {
            return
        }
        Task { @MainActor in
            self.deliverAvailable(handle)
        }
    }


    /// Reports that a track went away. Called on any thread. A key that is not registered is ignored.
    func trackDidGoAway(key: String) {
        let handle: LiveKitAudioTrackHandle? = withLock {
            return registry.unregister(key: key)
        }
        guard let handle: LiveKitAudioTrackHandle = handle else {
            return
        }
        Task { @MainActor in
            self.deliverRemoved(handle)
        }
    }


    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }


    @MainActor
    private func deliverAvailable(_ handle: LiveKitAudioTrackHandle) {
        let handler: ((LiveKitAudioTrackHandle) -> Void)? = availableHandler
        handler?(handle)
    }


    @MainActor
    private func deliverRemoved(_ handle: LiveKitAudioTrackHandle) {
        let handler: ((LiveKitAudioTrackHandle) -> Void)? = removedHandler
        handler?(handle)
    }
}
