import Foundation
import LiveKit


/// The kind of a local video track of a private call: the camera or the screen share.
public enum LiveKitPrivateVideoKind: Equatable {
    case camera
    case screen
}


/// Creates the local video track of a private call. The camera and the screen capturers conform to it.
public protocol LiveKitPrivateVideoCapturer: AnyObject {
    var videoKind: LiveKitPrivateVideoKind { get }

    @MainActor func makeLocalVideoTrack() async -> LiveKitLocalVideoTrack?
    /// Brings the track in line with the capturer state after it is published, because publishing starts the track.
    @MainActor func syncEnabledState() async
}


extension LiveKitPrivateVideoCapturer {
    @MainActor
    public func syncEnabledState() async {
    }
}


/// The state of a private call as the call screen reads it.
public struct LiveKitPrivateCallSnapshot: Equatable {
    public enum Connection: Equatable {
        case connecting
        case connected
        case ended(LiveKitCallEndReason)
    }

    public var connection: Connection
    /// The kind of the requested local video. Nil when the video is off and after the end.
    public var localVideo: LiveKitPrivateVideoKind?
    public var isRemoteVideoActive: Bool
    public var isRemoteAudioActive: Bool
}


/// Drives one 1:1 LiveKit call for the call screen. Settings made before the room connects are kept and applied on connect.
/// Media operations run one after another, and a failed one ends the call.
@MainActor
public final class LiveKitPrivateCall {
    public var onSnapshot: ((LiveKitPrivateCallSnapshot) -> Void)?
    public var onRemoteVideo: ((VideoTrack?) -> Void)?
    public private(set) var snapshot: LiveKitPrivateCallSnapshot

    private let context: LiveKitCallContext
    private var video: LiveKitPrivateVideoCapturer?
    private var isConnected: Bool = false
    private var isMicrophoneMuted: Bool = false
    private var audioInputId: String?
    private var audioOutputId: String?
    private var remoteTrack: RemoteVideoTrack?
    private var mediaTask: Task<Void, Never>?


    public convenience init(
        callId: Int64,
        versions: [String],
        parameters: String,
        authKey: Data
    ) throws {
        try self.init(context: LiveKitCallContext(
            callId: callId,
            versions: versions,
            parameters: parameters,
            authKey: authKey
        ))
    }


    init(context: LiveKitCallContext) {
        self.context = context
        self.snapshot = LiveKitPrivateCallSnapshot(
            connection: .connecting,
            localVideo: nil,
            isRemoteVideoActive: false,
            isRemoteAudioActive: true
        )
        context.onStateChanged = { [weak self] (state: LiveKitCallState) in
            self?.handleState(state)
        }
        context.onRemoteTracksChanged = { [weak self] in
            self?.refreshRemote()
        }
    }


    public func start() {
        context.start()
    }


    public func stop() {
        isConnected = false
        mediaTask?.cancel()
        mediaTask = nil
        context.stop()
    }


    public func setMuted(_ isMuted: Bool) {
        isMicrophoneMuted = isMuted
        enqueueMicrophone()
    }


    /// Publishes the track of the capturer in place of the current local video. Nil turns the video off.
    public func setVideo(_ capturer: LiveKitPrivateVideoCapturer?) {
        guard !isEnded, video !== capturer else {
            return
        }
        video = capturer
        var next: LiveKitPrivateCallSnapshot = snapshot
        next.localVideo = capturer?.videoKind
        setSnapshot(next)
        enqueueVideo()
    }


    public func setAudioInputDevice(_ id: String) {
        audioInputId = id
        enqueueAudioInput(id)
    }


    public func setAudioOutputDevice(_ id: String) {
        audioOutputId = id
        enqueueAudioOutput(id)
    }


    private var isEnded: Bool {
        if case .ended = snapshot.connection {
            return true
        }
        return false
    }


    private func handleState(_ state: LiveKitCallState) {
        switch state {
        case .connecting:
            return

        case .connected:
            isConnected = true
            var next: LiveKitPrivateCallSnapshot = snapshot
            next.connection = .connected
            setSnapshot(next)
            enqueueMicrophone()
            enqueueVideo()
            if let inputId: String = audioInputId {
                enqueueAudioInput(inputId)
            }
            if let outputId: String = audioOutputId {
                enqueueAudioOutput(outputId)
            }
            refreshRemote()

        case .ended(let reason):
            isConnected = false
            mediaTask?.cancel()
            mediaTask = nil
            video = nil
            remoteTrack = nil
            onRemoteVideo?(nil)
            var next: LiveKitPrivateCallSnapshot = snapshot
            next.connection = .ended(reason)
            next.localVideo = nil
            next.isRemoteVideoActive = false
            next.isRemoteAudioActive = false
            setSnapshot(next)
        }
    }


    /// Reads the remote video and audio of the room. Reports the video track only when it changes.
    private func refreshRemote() {
        guard !isEnded else {
            return
        }
        let remote: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve(context.media?.remoteParticipants ?? [])
        let track: RemoteVideoTrack? = remote.videoTrack
        if track !== remoteTrack {
            remoteTrack = track
            let videoTrack: VideoTrack? = track
            onRemoteVideo?(videoTrack)
        }
        var next: LiveKitPrivateCallSnapshot = snapshot
        next.isRemoteVideoActive = remote.isVideoActive
        next.isRemoteAudioActive = remote.isAudioActive
        setSnapshot(next)
    }


    private func setSnapshot(_ newSnapshot: LiveKitPrivateCallSnapshot) {
        guard newSnapshot != snapshot else {
            return
        }
        snapshot = newSnapshot
        onSnapshot?(newSnapshot)
    }


    private func enqueueMicrophone() {
        let isEnabled: Bool = !isMicrophoneMuted
        enqueueMedia { (media: LiveKitCallMedia) in
            try await media.setMicrophoneEnabled(isEnabled)
        }
    }


    /// Applies the requested video: the old kind is unpublished before the new track is published, so one local video exists at most.
    private func enqueueVideo() {
        let capturer: LiveKitPrivateVideoCapturer? = video
        enqueueMedia { (media: LiveKitCallMedia) in
            guard let capturer: LiveKitPrivateVideoCapturer = capturer else {
                try await media.unpublishCamera()
                try await media.unpublishScreenShare()
                return
            }
            switch capturer.videoKind {
            case .camera:
                try await media.unpublishScreenShare()
                guard let track: LiveKitLocalVideoTrack = await capturer.makeLocalVideoTrack() else {
                    return
                }
                try await media.publishCamera(track)
                await capturer.syncEnabledState()

            case .screen:
                try await media.unpublishCamera()
                guard let track: LiveKitLocalVideoTrack = await capturer.makeLocalVideoTrack() else {
                    return
                }
                try await media.publishScreenShare(track)
            }
        }
    }


    private func enqueueAudioInput(_ deviceId: String) {
        enqueueMedia { (media: LiveKitCallMedia) in
            try await media.setAudioInputDevice(id: deviceId)
        }
    }


    private func enqueueAudioOutput(_ deviceId: String) {
        enqueueMedia { (media: LiveKitCallMedia) in
            try await media.setAudioOutputDevice(id: deviceId)
        }
    }


    /// Runs one media operation of the connected room after the operations queued before it. Operations before the connection are dropped, because the connection applies the current state.
    /// A failed operation ends the call.
    private func enqueueMedia(_ operation: @escaping (LiveKitCallMedia) async throws -> Void) {
        guard isConnected, let media: LiveKitCallMedia = context.media else {
            return
        }
        let previous: Task<Void, Never>? = mediaTask
        mediaTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else {
                return
            }
            do {
                try await operation(media)
            } catch {
                self?.context.failMediaUpdate()
            }
        }
    }
}
