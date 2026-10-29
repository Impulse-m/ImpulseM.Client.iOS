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
}


/// A room session of a group connection. Its media seam is the local participant of the room. A session without a room reports nil.
protocol LiveKitGroupRoomSession: LiveKitRoomSession {
    var media: LiveKitRoomMedia? { get }
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
    private var mainSession: LiveKitRoomSession?
    private var presentationSession: LiveKitRoomSession?
    private var endpointsByPeer: [String: Set<String>] = [:]
    private var mainJoinTask: Task<Void, Never>?
    private var presentationJoinTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var presentationTrack: LiveKitLocalVideoTrack?
    private var cameraTrack: LiveKitLocalVideoTrack?
    private var cameraOperation: Task<Void, Never>?


    public convenience init(
        callId: Int64,
        joinRequest: @escaping LiveKitGroupJoinFunction,
        checkRequest: @escaping LiveKitGroupCheckFunction,
        leavePresentationRequest: @escaping LiveKitGroupLeaveFunction
    ) {
        self.init(
            callId: callId,
            joinRequest: joinRequest,
            checkRequest: checkRequest,
            leavePresentationRequest: leavePresentationRequest,
            pollIntervalSeconds: LiveKitGroupCallContext.pollIntervalSeconds,
            nextSource: LiveKitGroupCallContext.randomSource,
            makeSession: LiveKitGroupCallContext.makeSDKSession
        )
    }


    init(
        callId: Int64,
        joinRequest: @escaping LiveKitGroupJoinFunction,
        checkRequest: @escaping LiveKitGroupCheckFunction,
        leavePresentationRequest: @escaping LiveKitGroupLeaveFunction,
        pollIntervalSeconds: TimeInterval,
        nextSource: @escaping () -> UInt32,
        makeSession: @escaping LiveKitGroupRoomSessionFactory
    ) {
        self.callId = callId
        self.joinRequest = joinRequest
        self.checkRequest = checkRequest
        self.leavePresentationRequest = leavePresentationRequest
        self.pollIntervalSeconds = pollIntervalSeconds
        self.nextSource = nextSource
        self.makeSession = makeSession
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
        setPresentationActive(false)
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
        enqueueCameraOperation(publishCurrentCamera)
    }


    /// Disables the camera of the main room. The publication is muted and stays in the room.
    public func disableCamera() {
        guard !isEnded else {
            return
        }
        cameraTrack = nil
        enqueueCameraOperation(muteCurrentCamera)
    }


    /// Reads the video endpoints of the other participants from a server participant update.
    /// A participant with no endpoint clears its earlier endpoints.
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


    private nonisolated static func randomSource() -> UInt32 {
        return UInt32.random(in: 1...UInt32.max)
    }


    private nonisolated static func makeSDKSession(_ sink: LiveKitGroupRoomEventSink) -> LiveKitGroupRoomSession {
        return LiveKitGroupSDKRoomSession(sink: sink)
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
        enqueueCameraOperation(publishCurrentCamera)
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


    /// Runs camera operations one after another, so a publish and a mute never overlap.
    private func enqueueCameraOperation(_ operation: @escaping @MainActor () async -> Void) {
        let previous: Task<Void, Never>? = cameraOperation
        cameraOperation = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }


    /// Publishes the current camera track into the main room, when the main connection is joined.
    private func publishCurrentCamera() async {
        guard let track: LiveKitLocalVideoTrack = cameraTrack, mainSource != 0, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        // A camera that cannot be published leaves the call without video. The call itself stays up.
        try? await media.publishCamera(track)
    }


    /// Mutes the camera publication of the main room, when no camera track is wanted and the main connection is joined.
    private func muteCurrentCamera() async {
        guard cameraTrack == nil, mainSource != 0, let media: LiveKitRoomMedia = mainMedia else {
            return
        }
        try? await media.setCameraEnabled(false)
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
        presentationRequested = false
        presentationTrack = nil
        cameraTrack = nil
        mainGeneration += 1
        presentationGeneration += 1
        mainJoinTask?.cancel()
        presentationJoinTask?.cancel()
        pollTask?.cancel()
        setPresentationActive(false)
        Task { @MainActor in
            if wasPresenting {
                await leave()
            }
            await presentation?.disconnect()
            await main?.disconnect()
        }
        setState(.ended(reason))
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
}
