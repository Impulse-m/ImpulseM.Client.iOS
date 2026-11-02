#if os(iOS)
import Foundation
import LiveKit
import SwiftSignalKit


private extension OngoingCallContextState {
    static var initial: OngoingCallContextState {
        return OngoingCallContextState(
            state: .initializing,
            videoState: .inactive,
            remoteVideoState: .inactive,
            remoteAudioState: .active,
            remoteBatteryLevel: .normal
        )
    }


    static var failedToCreate: OngoingCallContextState {
        return OngoingCallContextState(
            state: .failed,
            videoState: .inactive,
            remoteVideoState: .inactive,
            remoteAudioState: .active,
            remoteBatteryLevel: .normal
        )
    }


    init(_ snapshot: LiveKitPrivateCallSnapshot) {
        let mappedState: OngoingCallContextState.State
        switch snapshot.connection {
        case .connecting:
            mappedState = .initializing

        case .connected:
            mappedState = .connected

        case .ended:
            mappedState = .failed
        }
        self.init(
            state: mappedState,
            videoState: snapshot.localVideo != nil ? .active : .inactive,
            remoteVideoState: snapshot.isRemoteVideoActive ? .active : .inactive,
            remoteAudioState: snapshot.isRemoteAudioActive ? .active : .muted,
            remoteBatteryLevel: .normal
        )
    }
}


/// Owns the LiveKit private call of one call. The call is main-actor isolated, so every access runs in a main-actor task.
///
/// Values set before the call is created are kept and applied on creation, and the start waits for the creation, so the order of the tasks does not matter.
private final class LiveKitOngoingCallBridge: @unchecked Sendable {
    private var call: LiveKitPrivateCall?
    private var isMuted: Bool
    private var video: LiveKitPrivateVideoCapturer?
    private var isStartRequested: Bool = false
    private var isStarted: Bool = false
    private var isStopped: Bool = false
    private var previousAutomaticConfiguration: Bool?
    private let reportState: (OngoingCallContextState) -> Void
    private let reportRemoteVideo: (VideoTrack?) -> Void


    init(
        isMuted: Bool,
        video: LiveKitPrivateVideoCapturer?,
        reportState: @escaping (OngoingCallContextState) -> Void,
        reportRemoteVideo: @escaping (VideoTrack?) -> Void
    ) {
        self.isMuted = isMuted
        self.video = video
        self.reportState = reportState
        self.reportRemoteVideo = reportRemoteVideo
    }


    /// Creates the call and applies the values set before it. A parameter or key error reports a failed state.
    @MainActor
    func create(
        callId: Int64,
        version: String,
        customParameters: String,
        key: Data
    ) {
        let created: LiveKitPrivateCall
        do {
            created = try LiveKitPrivateCall(
                callId: callId,
                versions: [version],
                parameters: customParameters,
                authKey: key
            )
        } catch {
            self.reportState(OngoingCallContextState.failedToCreate)
            return
        }
        created.onSnapshot = { (snapshot: LiveKitPrivateCallSnapshot) in
            self.reportState(OngoingCallContextState(snapshot))
            if case .ended = snapshot.connection {
                Task { @MainActor in
                    self.finish()
                }
            }
        }
        created.onRemoteVideo = { [weak self] (track: VideoTrack?) in
            self?.reportRemoteVideo(track)
        }
        created.setMuted(self.isMuted)
        if let video: LiveKitPrivateVideoCapturer = self.video {
            created.setVideo(video)
        }
        self.call = created
        if self.isStopped {
            created.stop()
        } else if self.isStartRequested {
            self.connect(created)
        }
    }


    @MainActor
    func start() {
        self.isStartRequested = true
        guard let call: LiveKitPrivateCall = self.call else {
            return
        }
        self.connect(call)
    }


    @MainActor
    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
        self.call?.setMuted(isMuted)
    }


    @MainActor
    func setVideo(_ capturer: LiveKitPrivateVideoCapturer?) {
        self.video = capturer
        self.call?.setVideo(capturer)
    }


    @MainActor
    func stop() {
        self.isStopped = true
        self.call?.stop()
    }


    /// The app owns the AVAudioSession (ManagedAudioSession and CallKit), so the SDK must not configure it while the call runs.
    /// The SDK setting is process-wide, so it is restored when the call ends.
    @MainActor
    private func connect(_ call: LiveKitPrivateCall) {
        guard !self.isStarted, !self.isStopped else {
            return
        }
        self.isStarted = true
        self.previousAutomaticConfiguration = AudioManager.shared.audioSession.isAutomaticConfigurationEnabled
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        call.start()
    }


    /// Runs when the call has ended and the room has left. Restores the SDK setting and releases the call.
    @MainActor
    private func finish() {
        self.restoreAudioSessionConfiguration()
        self.call = nil
    }


    /// Returns the SDK setting to its value before the call, so later LiveKit sessions such as group calls keep the SDK default.
    @MainActor
    private func restoreAudioSessionConfiguration() {
        guard let previous: Bool = self.previousAutomaticConfiguration else {
            return
        }
        self.previousAutomaticConfiguration = nil
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = previous
    }
}


/// The 1:1 call context of the iOS client on LiveKit. It offers the surface of `OngoingCallContext` that the call session reads.
///
/// The state and the remote video are reported through signals. Every call hops to the main actor.
public final class LiveKitOngoingCallContext {
    public var state: Signal<OngoingCallContextState, NoError> {
        return self.contextState.get()
    }


    private let contextState: Promise<OngoingCallContextState>
    private let remoteVideoPromise: Promise<VideoTrack?>
    private let bridge: LiveKitOngoingCallBridge


    /// Creates the call. A parameter or key error is reported as a failed state. Call `start()` only after the audio session is active.
    public init(
        callId: Int64,
        version: String,
        customParameters: String,
        key: Data,
        isMuted: Bool,
        video: LiveKitPrivateVideoCapturer?
    ) {
        let contextState: Promise<OngoingCallContextState> = Promise<OngoingCallContextState>(OngoingCallContextState.initial)
        let remoteVideoPromise: Promise<VideoTrack?> = Promise<VideoTrack?>(nil)
        self.contextState = contextState
        self.remoteVideoPromise = remoteVideoPromise
        let bridge: LiveKitOngoingCallBridge = LiveKitOngoingCallBridge(
            isMuted: isMuted,
            video: video,
            reportState: { (state: OngoingCallContextState) in
                contextState.set(.single(state))
            },
            reportRemoteVideo: { (track: VideoTrack?) in
                remoteVideoPromise.set(.single(track))
            }
        )
        self.bridge = bridge
        Task { @MainActor in
            bridge.create(callId: callId, version: version, customParameters: customParameters, key: key)
        }
    }


    deinit {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.stop()
        }
    }


    /// Connects the room of the call.
    public func start() {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.start()
        }
    }


    public func setIsMuted(_ isMuted: Bool) {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.setMuted(isMuted)
        }
    }


    /// Publishes the local video of the capturer. A requested video replaces the local video of the other kind.
    public func requestVideo(_ capturer: LiveKitPrivateVideoCapturer) {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.setVideo(capturer)
        }
    }


    public func disableVideo() {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.setVideo(nil)
        }
    }


    /// The remote video of the call as frames. Emits nothing while the call has no remote video.
    public func remoteVideo() -> Signal<OngoingGroupCallContext.VideoFrameData, NoError> {
        return LiveKitVideoFrames.frames(of: self.remoteVideoPromise.get())
    }


    public func stop() {
        let bridge: LiveKitOngoingCallBridge = self.bridge
        Task { @MainActor in
            bridge.stop()
        }
    }
}
#endif
