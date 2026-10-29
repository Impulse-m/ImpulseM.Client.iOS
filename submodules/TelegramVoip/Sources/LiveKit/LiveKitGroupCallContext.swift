import Foundation
import LiveKit


/// The state of a group LiveKit call.
public enum LiveKitGroupCallState: Equatable {
    case connecting
    case connected
    case ended(LiveKitGroupEndReason)
}


/// Why a group LiveKit call ended.
public enum LiveKitGroupEndReason: Equatable {
    case hungUp
    case joinFailed
    case connectionFailed
    case disconnected
    case groupCallInvalid
}


/// A server refusal of a group join request.
public enum LiveKitGroupJoinError: Error, Equatable {
    /// The server refused the sources as duplicates. The client regenerates them and joins again.
    case ssrcDuplicateMuch
    /// Any other refusal, with the server error text.
    case serverError(String)
}


/// A failure of the call-sources check. `badRequest` means the server refused the check, `groupCallInvalid` means the call is gone.
/// Any other failure is transient and the next check runs as usual.
public enum LiveKitGroupCheckError: Error, Equatable {
    case badRequest
    case groupCallInvalid
    case other
}


/// The server answer to a group join: the LiveKit join parameters of the connection and the participants that the answer reports.
public struct LiveKitGroupJoinResponse: Equatable {
    public let params: String
    public let participants: [LiveKitGroupParticipant]


    public init(
        params: String,
        participants: [LiveKitGroupParticipant]
    ) {
        self.params = params
        self.participants = participants
    }
}


/// One participant from the server participant list. Video endpoints are read from this list, never from the join answer.
public struct LiveKitGroupParticipant: Equatable {
    public let peerKey: String
    public let isSelf: Bool
    public let videoEndpoint: String?
    public let presentationEndpoint: String?


    public init(
        peerKey: String,
        isSelf: Bool,
        videoEndpoint: String?,
        presentationEndpoint: String?
    ) {
        self.peerKey = peerKey
        self.isSelf = isSelf
        self.videoEndpoint = videoEndpoint
        self.presentationEndpoint = presentationEndpoint
    }
}


/// The join payload of a group connection: the connection SSRC and the tgcalls-shaped JSON that the join request carries.
public struct LiveKitGroupJoinPayload: Equatable {
    public let ssrc: UInt32
    public let json: String


    public init(
        ssrc: UInt32,
        json: String
    ) {
        self.ssrc = ssrc
        self.json = json
    }


    /// Builds a payload with distinct, non-zero sources. A main connection has three simulcast layers, and a presentation has one layer.
    /// Every layer has a retransmission source. The sources are the same shape as the Android join payload.
    public static func make(
        isPresentation: Bool,
        nextSource: () -> UInt32
    ) -> LiveKitGroupJoinPayload {
        var used: Set<UInt32> = []
        let ssrc: UInt32 = uniqueSource(nextSource: nextSource, used: &used)
        let layerCount: Int = isPresentation ? 1 : 3
        var layers: [UInt32] = []
        for _ in 0..<layerCount {
            layers.append(uniqueSource(nextSource: nextSource, used: &used))
        }
        var groups: [String] = []
        if !isPresentation {
            groups.append(sourceGroup(semantics: "SIM", sources: layers))
        }
        for layer: UInt32 in layers {
            let retransmission: UInt32 = uniqueSource(nextSource: nextSource, used: &used)
            groups.append(sourceGroup(semantics: "FID", sources: [layer, retransmission]))
        }
        let json: String = "{\"ssrc\":\(ssrc),\"ssrc-groups\":[\(groups.joined(separator: ","))]}"
        return LiveKitGroupJoinPayload(ssrc: ssrc, json: json)
    }


    private static func uniqueSource(
        nextSource: () -> UInt32,
        used: inout Set<UInt32>
    ) -> UInt32 {
        var source: UInt32 = 0
        repeat {
            source = nextSource()
        } while source == 0 || !used.insert(source).inserted
        return source
    }


    private static func sourceGroup(
        semantics: String,
        sources: [UInt32]
    ) -> String {
        let values: String = sources.map { (source: UInt32) -> String in
            return String(source)
        }.joined(separator: ",")
        return "{\"semantics\":\"\(semantics)\",\"sources\":[\(values)]}"
    }
}


/// Sends a group join request and returns the answer. The payload is the JSON of `LiveKitGroupJoinPayload`. `isPresentation` selects the screen connection.
public typealias LiveKitGroupJoinFunction = (
    _ payload: String,
    _ isPresentation: Bool
) async throws -> LiveKitGroupJoinResponse


/// Checks which of the given call sources the server still reports. Returns the sources that are still present.
public typealias LiveKitGroupCheckFunction = (
    _ sources: [UInt32]
) async throws -> [UInt32]


/// Leaves the screen presentation on the server. The answer is not needed: a failed leave still ends the local presentation.
public typealias LiveKitGroupLeaveFunction = () async -> Void


/// A call on the group call context, posted from any thread with `LiveKitGroupCallContext.post(_:)`. Each case names one isolated method of the context,
/// with the same parameters, and the context runs the cases in the order they were posted.
public enum LiveKitGroupCallCommand {
    case setMuted(Bool)
    case switchAudioInput(String)
    case switchAudioOutput(String)
    case updateParticipants([LiveKitGroupParticipant])
    case setVolume(ssrc: UInt32, volume: Double)
    case setRequestedVideoChannels([LiveKitGroupVideoRequest])
    case disableCamera
    case remoteVideoTrack(endpoint: String, completion: @MainActor (LiveKitGroupRemoteVideoTrack?) -> Void)
}


/// The FIFO of posted group call commands. It is locked, so commands can be appended from any thread.
private final class LiveKitGroupCallCommandQueue: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var commands: [LiveKitGroupCallCommand] = []


    func append(_ command: LiveKitGroupCallCommand) {
        lock.lock()
        defer {
            lock.unlock()
        }
        commands.append(command)
    }


    /// Removes and returns every pending command, in the order they were posted.
    func takeAll() -> [LiveKitGroupCallCommand] {
        lock.lock()
        defer {
            lock.unlock()
        }
        let taken: [LiveKitGroupCallCommand] = commands
        commands = []
        return taken
    }
}


/// The kind of a group room: the main camera connection or the screen presentation connection.
enum LiveKitGroupRoomKind: Equatable {
    case main
    case presentation
}


/// Receives the failure events of one group room.
@MainActor
protocol LiveKitGroupRoomEventSink: AnyObject {
    func roomDidFailToConnect()
    func roomDidDisconnectUnexpectedly()

    /// A track of the room was subscribed or unsubscribed, so the remote video of the room may have changed.
    func roomRemoteTracksDidChange()
}


/// A room session of a group connection. Its media seam is the local participant of the room. A session without a room reports nil.
protocol LiveKitGroupRoomSession: LiveKitRoomSession {
    var media: LiveKitRoomMedia? { get }

    /// The remote participants of the room. Their video publications carry the remote video of the call.
    var remoteParticipants: [LiveKitGroupRemoteParticipant] { get }
}


/// Creates the room session of a group connection from the sink that receives its events.
typealias LiveKitGroupRoomSessionFactory = (LiveKitGroupRoomEventSink) -> LiveKitGroupRoomSession


/// The group LiveKit call engine. It joins the main connection, polls the call sources and rejoins after eviction,
/// and it runs the screen presentation as a second room. Any hard disconnect or failed connection ends the whole call.
///
/// Group rooms have no key provider: group calls are not end-to-end encrypted.
@MainActor
public final class LiveKitGroupCallContext {
    /// Seconds between two checks of the call sources. Android checks every 4 seconds.
    public static let pollIntervalSeconds: TimeInterval = 4

    public private(set) var state: LiveKitGroupCallState = .connecting
    public var onStateChanged: ((LiveKitGroupCallState) -> Void)?
    public private(set) var isPresentationActive: Bool = false
    public var onPresentationStateChanged: ((Bool) -> Void)?
    /// Whether the local microphone is muted. The microphone is muted at first, as on Android, unless the call starts unmuted.
    public private(set) var isMuted: Bool
    public var onMutedChanged: ((Bool) -> Void)?
    public private(set) var isNoiseSuppressionEnabled: Bool = AudioCaptureOptions.defaultNoiseSuppression
    /// Receives the audio levels of the group rooms every 100 ms, as `(key, level, speaking)` entries. The local microphone comes first, then the sources.
    /// The presentation room reports its own sources under their source keys.
    public var onAudioLevels: (([(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void)?

    /// Called on the main actor when a track of the main room is subscribed or unsubscribed, and when the call ends.
    /// A remote video view looks its track up again through `remoteVideoTrack(endpoint:)` when this fires.
    public var onRemoteTracksChanged: (() -> Void)?

    /// The video endpoints of the other participants, read from the participant list.
    public var remoteEndpoints: Set<String> {
        var endpoints: Set<String> = []
        for peerEndpoints: Set<String> in endpointsByPeer.values {
            endpoints.formUnion(peerEndpoints)
        }
        return endpoints
    }

    private let callId: Int64
    private let joinRequest: LiveKitGroupJoinFunction
    private let checkRequest: LiveKitGroupCheckFunction
    private let leavePresentationRequest: LiveKitGroupLeaveFunction
    private let pollIntervalSeconds: TimeInterval
    private let nextSource: () -> UInt32
    private let makeSession: LiveKitGroupRoomSessionFactory
    private var hasStarted: Bool = false
    private var presentationRequested: Bool = false
    private var mainSource: UInt32 = 0
    private var presentationSource: UInt32 = 0
    private var mainGeneration: Int = 0
    private var presentationGeneration: Int = 0
    private(set) var mainMedia: LiveKitRoomMedia?
    private(set) var presentationMedia: LiveKitRoomMedia?
    private var mainSession: LiveKitGroupRoomSession?
    private var presentationSession: LiveKitGroupRoomSession?
    private var endpointsByPeer: [String: Set<String>] = [:]
    /// The playout volume of each remote source, as the call set it. It is applied to the source's track when the track appears too.
    private var volumesBySource: [UInt32: Double] = [:]
    /// The video channels the call requests from the main room. A publication that is not requested is disabled.
    private var videoRequests: [LiveKitGroupVideoRequest] = []
    private var mainJoinTask: Task<Void, Never>?
    private var presentationJoinTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var presentationTrack: LiveKitLocalVideoTrack?
    private var cameraTrack: LiveKitLocalVideoTrack?
    private var mediaOperation: Task<Void, Never>?
    private let mainAudioLevels: LiveKitGroupRoomAudioLevels
    private let presentationAudioLevels: LiveKitGroupRoomAudioLevels
    private let audioLevelIntervalSeconds: TimeInterval
    private var audioLevelTask: Task<Void, Never>?
    private var audioInputId: String?
    private var audioOutputId: String?
    private nonisolated let commandQueue: LiveKitGroupCallCommandQueue = LiveKitGroupCallCommandQueue()


    public convenience init(
        callId: Int64,
        joinRequest: @escaping LiveKitGroupJoinFunction,
        checkRequest: @escaping LiveKitGroupCheckFunction,
        leavePresentationRequest: @escaping LiveKitGroupLeaveFunction,
        initialMuted: Bool = true,
        prioritizeVP8: Bool = false
    ) {
        let makeSession: LiveKitGroupRoomSessionFactory = { (sink: LiveKitGroupRoomEventSink) -> LiveKitGroupRoomSession in
            return LiveKitGroupSDKRoomSession(
                sink: sink,
                prioritizeVP8: prioritizeVP8
            )
        }
        self.init(
            callId: callId,
            joinRequest: joinRequest,
            checkRequest: checkRequest,
            leavePresentationRequest: leavePresentationRequest,
            initialMuted: initialMuted,
            pollIntervalSeconds: LiveKitGroupCallContext.pollIntervalSeconds,
            nextSource: LiveKitGroupCallContext.randomSource,
            makeSession: makeSession,
            audioLevelClock: LiveKitSystemAudioLevelClock(),
            makeAudioMeter: LiveKitGroupCallContext.makeGroupAudioMeter,
            audioLevelIntervalSeconds: TimeInterval(LiveKitGroupAudioLevels.sampleIntervalMilliseconds) / 1000
        )
    }


    init(
        callId: Int64,
        joinRequest: @escaping LiveKitGroupJoinFunction,
        checkRequest: @escaping LiveKitGroupCheckFunction,
        leavePresentationRequest: @escaping LiveKitGroupLeaveFunction,
        initialMuted: Bool = true,
        pollIntervalSeconds: TimeInterval,
        nextSource: @escaping () -> UInt32,
        makeSession: @escaping LiveKitGroupRoomSessionFactory,
        audioLevelClock: LiveKitAudioLevelClock,
        makeAudioMeter: @escaping () -> LiveKitAudioLevelMeter,
        audioLevelIntervalSeconds: TimeInterval
    ) {
        self.callId = callId
        self.joinRequest = joinRequest
        self.checkRequest = checkRequest
        self.leavePresentationRequest = leavePresentationRequest
        self.isMuted = initialMuted
        self.pollIntervalSeconds = pollIntervalSeconds
        self.nextSource = nextSource
        self.makeSession = makeSession
        self.mainAudioLevels = LiveKitGroupRoomAudioLevels(clock: audioLevelClock, makeMeter: makeAudioMeter)
        self.presentationAudioLevels = LiveKitGroupRoomAudioLevels(clock: audioLevelClock, makeMeter: makeAudioMeter)
        self.audioLevelIntervalSeconds = audioLevelIntervalSeconds
        self.mainAudioLevels.setLocalMuted(initialMuted)
    }


    /// Joins the main connection. Set `onStateChanged` before calling this. The call starts only once.
    public func start() {
        guard !hasStarted, !isEnded else {
            return
        }
        hasStarted = true
        startMainJoin()
    }


    /// Ends the call. The state reports the end at once; the rooms are left in the background.
    public func stop() {
        end(.hungUp)
    }


    /// Starts the screen presentation as a second room. The server accepts it only while the main connection is joined.
    /// The track is published into the presentation room once that room connects.
    public func startPresentation(track: LiveKitLocalVideoTrack) {
        guard state == .connected, !presentationRequested else {
            return
        }
        presentationRequested = true
        presentationTrack = track
        startPresentationJoin()
    }


    /// Stops the screen presentation: unpublishes the track, leaves it on the server and disconnects its room.
    /// `onPresentationStateChanged` reports the stop, also when the presentation was refused or failed before it became active.
    public func stopPresentation() {
        guard presentationRequested else {
            return
        }
        presentationRequested = false
        presentationTrack = nil
        presentationGeneration += 1
        presentationJoinTask?.cancel()
        presentationJoinTask = nil
        presentationSource = 0
        let session: LiveKitRoomSession? = presentationSession
        let media: LiveKitRoomMedia? = presentationMedia
        presentationSession = nil
        presentationMedia = nil
        let leave: LiveKitGroupLeaveFunction = leavePresentationRequest
        presentationAudioLevels.removeAll()
        let wasActive: Bool = isPresentationActive
        setPresentationActive(false)
        if !wasActive {
            onPresentationStateChanged?(false)
        }
        Task { @MainActor in
            try? await media?.unpublishScreenShare()
            await leave()
            await session?.disconnect()
        }
    }


    /// Publishes the camera track into the main room. The track is published at once when the main connection is joined,
    /// and again after every rejoin, until `disableCamera()` is called.
    public func setCamera(track: LiveKitLocalVideoTrack) {
        guard !isEnded else {
            return
        }
        cameraTrack = track
        enqueueMediaOperation(publishCurrentCamera)
    }


    /// Disables the camera of the main room. The publication is muted and stays in the room.
    public func disableCamera() {
        guard !isEnded else {
            return
        }
        cameraTrack = nil
        enqueueMediaOperation(muteCurrentCamera)
    }


    /// Mutes or unmutes the local microphone. The mute is applied at once when the main connection is joined,
    /// and on connect otherwise.
    public func setMuted(_ muted: Bool) {
        guard !isEnded, isMuted != muted else {
            return
        }
        isMuted = muted
        mainAudioLevels.setLocalMuted(muted)
        onMutedChanged?(muted)
        enqueueMediaOperation(applyMicrophone)
    }


    /// Turns the noise suppression of the microphone on or off. The setting is kept across rejoins.
    public func setNoiseSuppressionEnabled(_ enabled: Bool) {
        guard !isEnded, isNoiseSuppressionEnabled != enabled else {
            return
        }
        isNoiseSuppressionEnabled = enabled
        enqueueMediaOperation(applyNoiseSuppression)
    }


    /// Selects the microphone of the main room by its device id. The id is kept and applied again on every connect.
    /// An id that no device owns is ignored by the media seam.
    public func switchAudioInput(_ deviceId: String) {
        guard !isEnded else {
            return
        }
        audioInputId = deviceId
        enqueueMediaOperation(applyAudioInput)
    }


    /// Selects the speaker of the main room by its device id. The id is kept and applied again on every connect.
    /// An id that no device owns is ignored by the media seam.
    public func switchAudioOutput(_ deviceId: String) {
        guard !isEnded else {
            return
        }
        audioOutputId = deviceId
        enqueueMediaOperation(applyAudioOutput)
    }


    /// Sets the playout volume of the audio of a remote source, from 0 to 10, where 1 is unity gain. 0 mutes the track.
    /// The volume is kept for the source, so a track that appears later is played at it too.
    public func setVolume(ssrc: UInt32, volume: Double) {
        let clamped: Double = min(max(volume, 0), 10)
        volumesBySource[ssrc] = clamped
        mainAudioLevels.setPlaybackVolume(source: ssrc, volume: clamped)
        presentationAudioLevels.setPlaybackVolume(source: ssrc, volume: clamped)
    }


    /// Sets the video channels that the call requests from the main room. A requested endpoint is enabled at its quality,
    /// and every other video publication of the room is disabled. The request is applied once the main connection is joined.
    public func setRequestedVideoChannels(_ requests: [LiveKitGroupVideoRequest]) {
        guard !isEnded else {
            return
        }
        videoRequests = requests
        enqueueMediaOperation(applyVideoRequests)
    }


    /// The remote video track of the main room that belongs to the endpoint. A presentation endpoint (ending in `.p`) is matched as it is.
    /// Returns nil while the main room is not joined, when no participant owns the endpoint, or when that participant has no track yet.
    public func remoteVideoTrack(endpoint: String) -> LiveKitGroupRemoteVideoTrack? {
        guard let session: LiveKitGroupRoomSession = mainSession else {
            return nil
        }
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: { () -> [LiveKitGroupRemoteParticipant] in
            return session.remoteParticipants
        })
        return remoteVideo.videoTrack(endpoint: endpoint)
    }


    /// Reads the video endpoints of the other participants from a server participant update.
    /// A participant with no endpoint clears its earlier endpoints, so a participant that left is sent with no endpoints.
    public func updateParticipants(_ participants: [LiveKitGroupParticipant]) {
        for participant: LiveKitGroupParticipant in participants where !participant.isSelf {
            var endpoints: Set<String> = []
            if let videoEndpoint: String = participant.videoEndpoint {
                endpoints.insert(videoEndpoint)
            }
            if let presentationEndpoint: String = participant.presentationEndpoint {
                endpoints.insert(presentationEndpoint)
            }
            endpointsByPeer[participant.peerKey] = endpoints
        }
        enqueueMediaOperation(applyVideoRequests)
    }


    /// Queues a call on the context, to run on the main actor in the order it was posted. Safe from any thread.
    public nonisolated func post(_ command: LiveKitGroupCallCommand) {
        commandQueue.append(command)
        Task { @MainActor [weak self] in
            self?.drainCommands()
        }
    }


    /// Asks for the remote video track of the main room that belongs to the endpoint. The completion runs on the main actor with the answer,
    /// which is nil while the track is not available. Safe from any thread.
    public nonisolated func requestRemoteVideoTrack(
        endpoint: String,
        completion: @escaping @MainActor (LiveKitGroupRemoteVideoTrack?) -> Void
    ) {
        post(.remoteVideoTrack(endpoint: endpoint, completion: completion))
    }


    func roomDidFail(
        kind: LiveKitGroupRoomKind,
        identifier: Int
    ) {
        guard isCurrentRoom(kind: kind, identifier: identifier) else {
            return
        }
        end(.connectionFailed)
    }


    func roomDidDisconnect(
        kind: LiveKitGroupRoomKind,
        identifier: Int
    ) {
        guard isCurrentRoom(kind: kind, identifier: identifier) else {
            return
        }
        end(.disconnected)
    }


    /// Reports a subscription change of a room. Only the main room carries the remote video of the call, so the presentation room is ignored.
    func roomRemoteTracksDidChange(
        kind: LiveKitGroupRoomKind,
        identifier: Int
    ) {
        guard kind == .main, isCurrentRoom(kind: kind, identifier: identifier) else {
            return
        }
        onRemoteTracksChanged?()
    }


    /// Samples the audio levels of both rooms when the sample interval has passed, and reports them through `onAudioLevels`.
    /// Both rooms are sampled on every tick, so their windows stay aligned.
    func tickAudioLevels() {
        guard !isEnded else {
            return
        }
        let mainEntries: [(LiveKitGroupAudioLevelKey, Float, Bool)]? = mainAudioLevels.sample()
        let presentationEntries: [(LiveKitGroupAudioLevelKey, Float, Bool)]? = presentationAudioLevels.sample()
        guard mainEntries != nil || presentationEntries != nil else {
            return
        }
        var entries: [(LiveKitGroupAudioLevelKey, Float, Bool)] = mainEntries ?? []
        entries.append(contentsOf: presentationEntries ?? [])
        onAudioLevels?(entries)
    }


    private nonisolated static func makeGroupAudioMeter() -> LiveKitAudioLevelMeter {
        return LiveKitGroupAudioMeter()
    }


    private nonisolated static func randomSource() -> UInt32 {
        return UInt32.random(in: 1...UInt32.max)
    }


    private var isEnded: Bool {
        if case .ended = state {
            return true
        }
        return false
    }


    private func isCurrentRoom(
        kind: LiveKitGroupRoomKind,
        identifier: Int
    ) -> Bool {
        if isEnded {
            return false
        }
        switch kind {
        case .main:
            return identifier == mainGeneration && mainSession != nil

        case .presentation:
            return identifier == presentationGeneration && presentationSession != nil
        }
    }


    private func startMainJoin() {
        mainGeneration += 1
        mainSource = 0
        let generation: Int = mainGeneration
        mainJoinTask?.cancel()
        mainJoinTask = Task { @MainActor [weak self] in
            await self?.runMainJoin(generation: generation)
        }
    }


    private func runMainJoin(generation: Int) async {
        while generation == mainGeneration && !isEnded {
            let payload: LiveKitGroupJoinPayload = LiveKitGroupJoinPayload.make(
                isPresentation: false,
                nextSource: nextSource
            )
            let response: LiveKitGroupJoinResponse
            do {
                response = try await joinRequest(payload.json, false)
            } catch LiveKitGroupJoinError.ssrcDuplicateMuch {
                continue
            } catch {
                if generation == mainGeneration {
                    end(.joinFailed)
                }
                return
            }
            await connectMain(
                generation: generation,
                source: payload.ssrc,
                response: response
            )
            return
        }
    }


    private func connectMain(
        generation: Int,
        source: UInt32,
        response: LiveKitGroupJoinResponse
    ) async {
        let parameters: LiveKitJoinParameters
        do {
            parameters = try LiveKitJoinParameters.parse(
                json: response.params,
                isGroup: true,
                callId: callId
            )
        } catch {
            if generation == mainGeneration {
                end(.joinFailed)
            }
            return
        }
        guard generation == mainGeneration, !isEnded else {
            return
        }
        updateParticipants(response.participants)
        let previous: LiveKitRoomSession? = mainSession
        mainSession = nil
        mainMedia = nil
        mainAudioLevels.removeAll()
        await previous?.disconnect()
        guard generation == mainGeneration, !isEnded else {
            return
        }
        let sink: LiveKitGroupRoomSink = LiveKitGroupRoomSink(
            owner: self,
            kind: .main,
            identifier: generation
        )
        let session: LiveKitGroupRoomSession = makeSession(sink)
        mainSession = session
        mainMedia = session.media
        bindAudioTracks(media: session.media, kind: .main, generation: generation)
        do {
            try await session.connect(url: parameters.url, token: parameters.token)
        } catch {
            if generation == mainGeneration {
                end(.connectionFailed)
            }
            return
        }
        guard generation == mainGeneration, !isEnded else {
            await session.disconnect()
            return
        }
        mainSource = source
        if state == .connecting {
            setState(.connected)
        }
        startPolling()
        startAudioLevelTimer()
        enqueueMediaOperation(applyMainAudio)
        enqueueMediaOperation(applyAudioInput)
        enqueueMediaOperation(applyAudioOutput)
        enqueueMediaOperation(publishCurrentCamera)
        enqueueMediaOperation(applyVideoRequests)
    }


    private func startPresentationJoin() {
        guard state == .connected, presentationRequested, !isEnded else {
            return
        }
        presentationGeneration += 1
        presentationSource = 0
        let generation: Int = presentationGeneration
        presentationJoinTask?.cancel()
        presentationJoinTask = Task { @MainActor [weak self] in
            await self?.runPresentationJoin(generation: generation)
        }
    }


    private func runPresentationJoin(generation: Int) async {
        while generation == presentationGeneration && presentationRequested && !isEnded {
            let payload: LiveKitGroupJoinPayload = LiveKitGroupJoinPayload.make(
                isPresentation: true,
                nextSource: nextSource
            )
            let response: LiveKitGroupJoinResponse
            do {
                response = try await joinRequest(payload.json, true)
            } catch LiveKitGroupJoinError.ssrcDuplicateMuch {
                continue
            } catch {
                // A refused presentation stays off. It does not end the call.
                if generation == presentationGeneration {
                    stopPresentation()
                }
                return
            }
            await connectPresentation(
                generation: generation,
                source: payload.ssrc,
                response: response
            )
            return
        }
    }


    private func connectPresentation(
        generation: Int,
        source: UInt32,
        response: LiveKitGroupJoinResponse
    ) async {
        let parameters: LiveKitJoinParameters
        do {
            parameters = try LiveKitJoinParameters.parse(
                json: response.params,
                isGroup: true,
                callId: callId
            )
        } catch {
            if generation == presentationGeneration {
                end(.joinFailed)
            }
            return
        }
        guard generation == presentationGeneration, presentationRequested, !isEnded else {
            return
        }
        updateParticipants(response.participants)
        let previous: LiveKitRoomSession? = presentationSession
        presentationSession = nil
        presentationMedia = nil
        presentationAudioLevels.removeAll()
        await previous?.disconnect()
        guard generation == presentationGeneration, presentationRequested, !isEnded else {
            return
        }
        let sink: LiveKitGroupRoomSink = LiveKitGroupRoomSink(
            owner: self,
            kind: .presentation,
            identifier: generation
        )
        let session: LiveKitGroupRoomSession = makeSession(sink)
        presentationSession = session
        presentationMedia = session.media
        bindAudioTracks(media: session.media, kind: .presentation, generation: generation)
        do {
            try await session.connect(url: parameters.url, token: parameters.token)
        } catch {
            if generation == presentationGeneration {
                end(.connectionFailed)
            }
            return
        }
        guard generation == presentationGeneration, presentationRequested, !isEnded else {
            await session.disconnect()
            return
        }
        presentationSource = source
        if let track: LiveKitLocalVideoTrack = presentationTrack, let media: LiveKitRoomMedia = presentationMedia {
            do {
                try await media.publishScreenShare(track)
            } catch {
                // A presentation whose screen cannot be published stays off. It does not end the call.
                if generation == presentationGeneration {
                    stopPresentation()
                }
                return
            }
        }
        guard generation == presentationGeneration, presentationRequested, !isEnded else {
            return
        }
        setPresentationActive(true)
    }


    private func startPolling() {
        guard pollTask == nil else {
            return
        }
        let seconds: TimeInterval = self.pollIntervalSeconds
        pollTask = Task { @MainActor [weak self] in
            // The context is held only while a check runs, so a context that is no longer referenced stops polling.
            while true {
                let nanoseconds: UInt64 = LiveKitGroupCallContext.nanoseconds(from: seconds)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled, let owner: LiveKitGroupCallContext = self, !owner.isEnded else {
                    return
                }
                await owner.pollOnce()
            }
        }
    }


    private func pollOnce() async {
        let requestedMain: UInt32 = mainSource
        let requestedPresentation: UInt32 = presentationSource
        var sources: [UInt32] = []
        if requestedMain != 0 {
            sources.append(requestedMain)
        }
        if requestedPresentation != 0 {
            sources.append(requestedPresentation)
        }
        guard !sources.isEmpty else {
            return
        }
        do {
            let presentSources: [UInt32] = try await checkRequest(sources)
            guard !isEnded else {
                return
            }
            if requestedMain != 0 && requestedMain == mainSource && !presentSources.contains(requestedMain) {
                startMainJoin()
            }
            if requestedPresentation != 0 && requestedPresentation == presentationSource && !presentSources.contains(requestedPresentation) {
                startPresentationJoin()
            }
        } catch LiveKitGroupCheckError.badRequest {
            guard !isEnded else {
                return
            }
            if mainSource != 0 {
                startMainJoin()
            }
            if presentationSource != 0 {
                startPresentationJoin()
            }
        } catch LiveKitGroupCheckError.groupCallInvalid {
            end(.groupCallInvalid)
        } catch {
            // A transient failure keeps the call. The next check runs as usual.
        }
    }


    /// Routes the audio track events of one room to its levels. An event from a room that has been replaced or left is ignored.
    private func bindAudioTracks(
        media: LiveKitRoomMedia?,
        kind: LiveKitGroupRoomKind,
        generation: Int
    ) {
        guard let media: LiveKitRoomMedia = media else {
            return
        }
        media.onAudioTrackAvailable = { [weak self] (handle: LiveKitAudioTrackHandle) -> Void in
            self?.audioTrackDidAppear(handle, kind: kind, generation: generation)
        }
        media.onAudioTrackRemoved = { [weak self] (handle: LiveKitAudioTrackHandle) -> Void in
            self?.audioTrackDidGoAway(handle, kind: kind, generation: generation)
        }
    }


    private func audioTrackDidAppear(
        _ handle: LiveKitAudioTrackHandle,
        kind: LiveKitGroupRoomKind,
        generation: Int
    ) {
        guard isCurrentRoom(kind: kind, identifier: generation) else {
            return
        }
        audioLevels(kind: kind).trackDidAppear(handle)
        applyStoredVolume(to: handle)
    }


    /// Plays a remote track at the volume that the call set for its source. A track without a stored volume keeps the SDK default.
    private func applyStoredVolume(to handle: LiveKitAudioTrackHandle) {
        guard !handle.isLocal, let identity: LiveKitGroupIdentity = try? LiveKitGroupIdentity.parse(identity: handle.participantIdentity) else {
            return
        }
        guard let volume: Double = volumesBySource[identity.source] else {
            return
        }
        handle.setPlaybackVolume(volume)
    }


    private func audioTrackDidGoAway(
        _ handle: LiveKitAudioTrackHandle,
        kind: LiveKitGroupRoomKind,
        generation: Int
    ) {
        guard isCurrentRoom(kind: kind, identifier: generation) else {
            return
        }
        audioLevels(kind: kind).trackDidGoAway(handle)
    }


    private func audioLevels(kind: LiveKitGroupRoomKind) -> LiveKitGroupRoomAudioLevels {
        switch kind {
        case .main:
            return mainAudioLevels

        case .presentation:
            return presentationAudioLevels
        }
    }


    private func startAudioLevelTimer() {
        guard audioLevelTask == nil else {
            return
        }
        let seconds: TimeInterval = audioLevelIntervalSeconds
        audioLevelTask = Task { @MainActor [weak self] in
            // As the poll loop, the context is held only while a tick runs, so a context that is no longer referenced stops ticking.
            while true {
                try? await Task.sleep(nanoseconds: LiveKitGroupCallContext.nanoseconds(from: seconds))
                guard !Task.isCancelled, let owner: LiveKitGroupCallContext = self, !owner.isEnded else {
                    return
                }
                owner.tickAudioLevels()
            }
        }
    }


    /// Runs every pending command in the order it was posted. Each drain empties the whole queue, so a drain that runs after another one finds nothing left to do.
    private func drainCommands() {
        for command: LiveKitGroupCallCommand in commandQueue.takeAll() {
            switch command {
            case .setMuted(let muted):
                setMuted(muted)

            case .switchAudioInput(let deviceId):
                switchAudioInput(deviceId)

            case .switchAudioOutput(let deviceId):
                switchAudioOutput(deviceId)

            case .updateParticipants(let participants):
                updateParticipants(participants)

            case .setVolume(let ssrc, let volume):
                setVolume(ssrc: ssrc, volume: volume)

            case .setRequestedVideoChannels(let requests):
                setRequestedVideoChannels(requests)

            case .disableCamera:
                disableCamera()

            case .remoteVideoTrack(let endpoint, let completion):
                completion(remoteVideoTrack(endpoint: endpoint))
            }
        }
    }


    /// Runs media operations of the main room one after another, so a publish, a mute and a setting change never overlap.
    private func enqueueMediaOperation(_ operation: @escaping @MainActor () async -> Void) {
        let previous: Task<Void, Never>? = mediaOperation
        mediaOperation = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }


    /// Applies the noise suppression and then the mute of the main microphone, when the main connection is joined.
    /// The noise setting goes first, so a microphone published now captures with the current setting.
    private func applyMainAudio() async {
        await applyNoiseSuppression()
        await applyMicrophone()
    }


    /// Applies the mute of the main microphone. A microphone that cannot be published ends the call, as on Android.
    private func applyMicrophone() async {
        guard mainSource != 0, !isEnded, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        let generation: Int = mainGeneration
        let isEnabled: Bool = !isMuted
        do {
            try await media.setMicrophoneEnabled(isEnabled)
        } catch {
            if generation == mainGeneration {
                end(.connectionFailed)
            }
        }
    }


    /// Applies the noise suppression setting to the main microphone, when the main connection is joined.
    private func applyNoiseSuppression() async {
        guard mainSource != 0, !isEnded, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        let generation: Int = mainGeneration
        let isEnabled: Bool = isNoiseSuppressionEnabled
        do {
            try await media.setNoiseSuppressionEnabled(isEnabled)
        } catch {
            if generation == mainGeneration {
                end(.connectionFailed)
            }
        }
    }


    /// Applies the selected microphone to the main room, when the main connection is joined. A switch that fails keeps the current device.
    private func applyAudioInput() async {
        guard mainSource != 0, !isEnded, let media: LiveKitRoomMedia = mainMedia, let deviceId: String = audioInputId else {
            return
        }
        try? await media.setAudioInputDevice(id: deviceId)
    }


    /// Applies the selected speaker to the main room, when the main connection is joined. A switch that fails keeps the current device.
    private func applyAudioOutput() async {
        guard mainSource != 0, !isEnded, let media: LiveKitRoomMedia = mainMedia, let deviceId: String = audioOutputId else {
            return
        }
        try? await media.setAudioOutputDevice(id: deviceId)
    }


    /// Publishes the current camera track into the main room, when the main connection is joined.
    /// A camera that cannot be published ends the call, as on Android.
    private func publishCurrentCamera() async {
        guard let track: LiveKitLocalVideoTrack = cameraTrack, mainSource != 0, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        let generation: Int = mainGeneration
        do {
            try await media.publishCamera(track)
        } catch {
            if generation == mainGeneration {
                end(.connectionFailed)
            }
        }
    }


    /// Mutes the camera publication of the main room, when no camera track is wanted and the main connection is joined.
    private func muteCurrentCamera() async {
        guard cameraTrack == nil, mainSource != 0, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        try? await media.setCameraEnabled(false)
    }


    /// Applies the requested video channels to the publications of the main room, when the main connection is joined.
    /// A publication that refuses the change keeps its state, and the call goes on.
    private func applyVideoRequests() async {
        guard mainSource != 0, !isEnded, let session: LiveKitGroupRoomSession = mainSession else {
            return
        }
        let requests: [LiveKitGroupVideoRequest] = videoRequests
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: { () -> [LiveKitGroupRemoteParticipant] in
            return session.remoteParticipants
        })
        try? await remoteVideo.applyRequests(requests)
    }


    private func setState(_ newState: LiveKitGroupCallState) {
        state = newState
        onStateChanged?(newState)
    }


    private func setPresentationActive(_ active: Bool) {
        guard isPresentationActive != active else {
            return
        }
        isPresentationActive = active
        onPresentationStateChanged?(active)
    }


    private func end(_ reason: LiveKitGroupEndReason) {
        guard !isEnded else {
            return
        }
        let main: LiveKitRoomSession? = mainSession
        let presentation: LiveKitRoomSession? = presentationSession
        let wasPresenting: Bool = presentationRequested
        let leave: LiveKitGroupLeaveFunction = leavePresentationRequest
        mainSession = nil
        presentationSession = nil
        mainMedia = nil
        presentationMedia = nil
        mainAudioLevels.removeAll()
        presentationAudioLevels.removeAll()
        presentationRequested = false
        presentationTrack = nil
        cameraTrack = nil
        mainGeneration += 1
        presentationGeneration += 1
        mainJoinTask?.cancel()
        presentationJoinTask?.cancel()
        pollTask?.cancel()
        audioLevelTask?.cancel()
        setPresentationActive(false)
        Task { @MainActor in
            if wasPresenting {
                await leave()
            }
            await presentation?.disconnect()
            await main?.disconnect()
        }
        setState(.ended(reason))
        onRemoteTracksChanged?()
    }


    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        return UInt64(max(0, seconds) * 1_000_000_000)
    }
}


/// Forwards the failure events of one group room to the context, tagged with the room kind and the join generation that created it.
/// An event from a room that has been replaced or left is ignored by the context.
@MainActor
private final class LiveKitGroupRoomSink: LiveKitGroupRoomEventSink {
    private weak var owner: LiveKitGroupCallContext?
    private let kind: LiveKitGroupRoomKind
    private let identifier: Int


    init(
        owner: LiveKitGroupCallContext,
        kind: LiveKitGroupRoomKind,
        identifier: Int
    ) {
        self.owner = owner
        self.kind = kind
        self.identifier = identifier
    }


    func roomDidFailToConnect() {
        owner?.roomDidFail(kind: kind, identifier: identifier)
    }


    func roomDidDisconnectUnexpectedly() {
        owner?.roomDidDisconnect(kind: kind, identifier: identifier)
    }


    func roomRemoteTracksDidChange() {
        owner?.roomRemoteTracksDidChange(kind: kind, identifier: identifier)
    }
}


/// The level meters of the audio tracks of one group room. Each audio track that appears gets one meter, keyed by the local microphone
/// or by the source of its participant identity. A track that goes away has its meter detached and removed.
@MainActor
final class LiveKitGroupRoomAudioLevels {
    private struct Attachment {
        let handle: LiveKitAudioTrackHandle
        let key: LiveKitGroupAudioLevelKey
        let meter: LiveKitAudioLevelMeter
    }


    private let levels: LiveKitGroupAudioLevels
    private let makeMeter: () -> LiveKitAudioLevelMeter
    private var attachments: [ObjectIdentifier: Attachment] = [:]


    init(
        clock: LiveKitAudioLevelClock,
        makeMeter: @escaping () -> LiveKitAudioLevelMeter
    ) {
        self.levels = LiveKitGroupAudioLevels(clock: clock)
        self.makeMeter = makeMeter
    }


    /// Sets whether the local microphone is muted. A muted local track reports 0 and not speaking.
    func setLocalMuted(_ isMuted: Bool) {
        levels.setLocalMuted(isMuted)
    }


    /// Attaches a meter to a track that appeared. A track without a usable identity is not metered.
    /// A track whose key is already metered replaces the earlier track.
    func trackDidAppear(_ handle: LiveKitAudioTrackHandle) {
        let identifier: ObjectIdentifier = ObjectIdentifier(handle)
        guard attachments[identifier] == nil else {
            return
        }
        guard let key: LiveKitGroupAudioLevelKey = LiveKitGroupRoomAudioLevels.levelKey(for: handle) else {
            return
        }
        let replaced: [ObjectIdentifier] = attachments.filter { (entry: (key: ObjectIdentifier, value: Attachment)) -> Bool in
            return entry.value.key == key
        }.map { (entry: (key: ObjectIdentifier, value: Attachment)) -> ObjectIdentifier in
            return entry.key
        }
        for replacedIdentifier: ObjectIdentifier in replaced {
            detach(identifier: replacedIdentifier)
        }
        let meter: LiveKitAudioLevelMeter = makeMeter()
        levels.addMeter(key: key, meter: meter)
        handle.attachMeter(meter)
        attachments[identifier] = Attachment(
            handle: handle,
            key: key,
            meter: meter
        )
    }


    /// Sets the playout volume of the metered tracks that carry the source. Tracks of other sources are not changed.
    func setPlaybackVolume(source: UInt32, volume: Double) {
        for attachment: Attachment in attachments.values where attachment.key == .source(source) {
            attachment.handle.setPlaybackVolume(volume)
        }
    }


    /// Detaches and removes the meter of a track that went away.
    func trackDidGoAway(_ handle: LiveKitAudioTrackHandle) {
        detach(identifier: ObjectIdentifier(handle))
    }


    /// Detaches and removes every meter. Used when the room is replaced or left.
    func removeAll() {
        let identifiers: [ObjectIdentifier] = Array(attachments.keys)
        for identifier: ObjectIdentifier in identifiers {
            detach(identifier: identifier)
        }
    }


    /// Returns one entry per metered track when the sample interval has passed, and nil otherwise.
    func sample() -> [(LiveKitGroupAudioLevelKey, Float, Bool)]? {
        return levels.sampleIfDue()
    }


    private func detach(identifier: ObjectIdentifier) {
        guard let attachment: Attachment = attachments.removeValue(forKey: identifier) else {
            return
        }
        attachment.handle.detachMeter(attachment.meter)
        levels.removeMeter(key: attachment.key)
    }


    private static func levelKey(for handle: LiveKitAudioTrackHandle) -> LiveKitGroupAudioLevelKey? {
        if handle.isLocal {
            return .local
        }
        guard let identity: LiveKitGroupIdentity = try? LiveKitGroupIdentity.parse(identity: handle.participantIdentity) else {
            return nil
        }
        return .source(identity.source)
    }
}
