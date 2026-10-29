import AVFoundation
import Foundation
import LiveKit


/// Errors of the LiveKit room media seam.
enum LiveKitRoomMediaError: Error {
    /// The track handed to the seam is not backed by an SDK track, so it cannot be published.
    case trackHasNoSdkTrack
}


/// The LiveKit implementation of `LiveKitRoomMedia`, driven through the local participant of a room.
///
/// The call context runs the calls one at a time, so the noise suppression flag needs no lock.
final class LiveKitRoomMediaSDK: LiveKitRoomMedia {
    /// Called on the main actor when an audio track of the room becomes available. The value is stored by the audio track hub that the room delegate feeds.
    var onAudioTrackAvailable: ((LiveKitAudioTrackHandle) -> Void)? {
        get {
            return audioTracks.availableHandler
        }
        set {
            audioTracks.availableHandler = newValue
        }
    }


    /// Called on the main actor once when an audio track that was reported goes away. The value is stored by the audio track hub that the room delegate feeds.
    var onAudioTrackRemoved: ((LiveKitAudioTrackHandle) -> Void)? {
        get {
            return audioTracks.removedHandler
        }
        set {
            audioTracks.removedHandler = newValue
        }
    }


    private let localParticipant: LocalParticipant
    private let isGroupCall: Bool
    private let audioTracks: LiveKitAudioTrackHub
    private var isNoiseSuppressionEnabled: Bool = AudioCaptureOptions.defaultNoiseSuppression


    init(
        localParticipant: LocalParticipant,
        isGroupCall: Bool,
        audioTracks: LiveKitAudioTrackHub = LiveKitAudioTrackHub()
    ) {
        self.localParticipant = localParticipant
        self.isGroupCall = isGroupCall
        self.audioTracks = audioTracks
    }


    func setMicrophoneEnabled(_ isEnabled: Bool) async throws {
        let captureOptions: AudioCaptureOptions = LiveKitRoomMediaSDK.audioCaptureOptions(noiseSuppression: isNoiseSuppressionEnabled)
        // The SDK mutes or unmutes an existing microphone publication and publishes a new one only when none exists.
        try await localParticipant.setMicrophone(enabled: isEnabled, captureOptions: captureOptions)
    }


    func setNoiseSuppressionEnabled(_ isEnabled: Bool) async throws {
        isNoiseSuppressionEnabled = isEnabled
        guard let track: LocalAudioTrack = microphoneTrack() else {
            return
        }
        let options: AudioProcessingOptions = LiveKitRoomMediaSDK.audioProcessingOptions(noiseSuppression: isEnabled)
        // The SDK call blocks until the signaling thread applies the options, so it runs off the caller's thread.
        let applyTask: Task<Void, Error> = Task.detached(priority: .userInitiated) {
            _ = try track.setAudioProcessingOptions(options)
        }
        try await applyTask.value
    }


    func setCameraEnabled(_ isEnabled: Bool) async throws {
        let publishOptions: VideoPublishOptions = LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: isGroupCall)
        // The camera simulcast rule does not depend on the camera side, so the back code stands for any camera.
        // The SDK mutes or unmutes an existing camera publication and publishes a new one only when none exists.
        try await localParticipant.setCamera(enabled: isEnabled, publishOptions: publishOptions)
    }


    func publishCamera(_ track: LiveKitLocalVideoTrack) async throws {
        guard let sdkTrack: LocalVideoTrack = track.sdkTrack else {
            throw LiveKitRoomMediaError.trackHasNoSdkTrack
        }
        let publishOptions: VideoPublishOptions = LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: isGroupCall)
        let cameraPublications: [LocalTrackPublication] = localParticipant.localVideoTracks.filter { (publication: LocalTrackPublication) -> Bool in
            return publication.source == .camera
        }
        for publication: LocalTrackPublication in cameraPublications {
            try await localParticipant.unpublish(publication: publication)
        }
        try await localParticipant.publish(videoTrack: sdkTrack, options: publishOptions)
    }


    func publishScreenShare(_ track: LiveKitLocalVideoTrack) async throws {
        guard let sdkTrack: LocalVideoTrack = track.sdkTrack else {
            throw LiveKitRoomMediaError.trackHasNoSdkTrack
        }
        let publishOptions: VideoPublishOptions = LiveKitVideoSources.videoPublishOptions(captureCode: .screen, isGroupCall: isGroupCall)
        try await localParticipant.publish(videoTrack: sdkTrack, options: publishOptions)
    }


    func unpublishScreenShare() async throws {
        let publications: [LocalTrackPublication] = localParticipant.localVideoTracks
        guard let publication: LocalTrackPublication = publications.first(where: { $0.source == .screenShareVideo }) else {
            return
        }
        try await localParticipant.unpublish(publication: publication)
    }


    func setAudioInputDevice(id: String) async throws {
        #if os(macOS)
        guard let device: AudioDevice = LiveKitRoomMediaSDK.selectDevice(id: id, in: AudioManager.shared.inputDevices) else {
            return
        }
        AudioManager.shared.inputDevice = device
        #endif
    }


    func setAudioOutputDevice(id: String) async throws {
        #if os(macOS)
        guard let device: AudioDevice = LiveKitRoomMediaSDK.selectDevice(id: id, in: AudioManager.shared.outputDevices) else {
            return
        }
        AudioManager.shared.outputDevice = device
        #endif
    }


    /// The capture options of a microphone publication. Every other component keeps the SDK default.
    static func audioCaptureOptions(noiseSuppression: Bool) -> AudioCaptureOptions {
        return AudioCaptureOptions(noiseSuppression: noiseSuppression)
    }


    /// The processing options applied to a live microphone track. Every other component keeps the SDK default.
    static func audioProcessingOptions(noiseSuppression: Bool) -> AudioProcessingOptions {
        return AudioProcessingOptions(noiseSuppression: noiseSuppression)
    }


    /// The device whose identifier equals `id`, or nil when no device owns it.
    static func selectDevice<Device: Identifiable>(id: String, in devices: [Device]) -> Device? where Device.ID == String {
        return devices.first(where: { $0.id == id })
    }


    private func microphoneTrack() -> LocalAudioTrack? {
        let publications: [LocalTrackPublication] = localParticipant.localAudioTracks
        guard let publication: LocalTrackPublication = publications.first(where: { $0.source == .microphone }) else {
            return nil
        }
        return publication.track as? LocalAudioTrack
    }
}


/// The SDK side of an audio track of a room. It hands each meter to the SDK track as an audio renderer, and is the only object that touches the track.
final class LiveKitAudioTrackHandleSDK: LiveKitAudioTrackHandle, @unchecked Sendable {
    let participantIdentity: String
    let isLocal: Bool
    private let track: AudioTrack
    private let lock: NSLock = NSLock()
    private var renderers: [ObjectIdentifier: LiveKitAudioMeterRenderer] = [:]


    init(participantIdentity: String, isLocal: Bool, track: AudioTrack) {
        self.participantIdentity = participantIdentity
        self.isLocal = isLocal
        self.track = track
    }


    func attachMeter(_ meter: LiveKitAudioLevelMeter) {
        let key: ObjectIdentifier = ObjectIdentifier(meter)
        let renderer: LiveKitAudioMeterRenderer? = withLock {
            if renderers[key] != nil {
                return nil
            }
            let created: LiveKitAudioMeterRenderer = LiveKitAudioMeterRenderer(meter: meter)
            renderers[key] = created
            return created
        }
        guard let renderer: LiveKitAudioMeterRenderer = renderer else {
            return
        }
        track.add(audioRenderer: renderer)
    }


    func detachMeter(_ meter: LiveKitAudioLevelMeter) {
        let key: ObjectIdentifier = ObjectIdentifier(meter)
        let renderer: LiveKitAudioMeterRenderer? = withLock {
            return renderers.removeValue(forKey: key)
        }
        guard let renderer: LiveKitAudioMeterRenderer = renderer else {
            return
        }
        track.remove(audioRenderer: renderer)
    }


    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


/// Forwards the buffers of an SDK track to a meter. The SDK calls it on the audio thread.
final class LiveKitAudioMeterRenderer: AudioRenderer {
    private let meter: LiveKitAudioLevelMeter


    init(meter: LiveKitAudioLevelMeter) {
        self.meter = meter
    }


    func render(pcmBuffer: AVAudioPCMBuffer) {
        meter.render(pcmBuffer: pcmBuffer)
    }
}
