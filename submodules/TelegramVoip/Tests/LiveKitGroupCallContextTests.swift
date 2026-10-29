import XCTest
import LiveKit
@testable import TelegramVoip


private let testUrl: String = "wss://project.livekit.cloud"
private let testToken: String = "bearer-secret-token-value"
private let testGroupCallId: Int64 = 77
private let testWaitAttempts: Int = 200
private let testWaitStepNanoseconds: UInt64 = 10_000_000
private let testPollIntervalSeconds: TimeInterval = 0.01
private let testAudioLevel: Float = 0.4
private let testAudioLevelIntervalSeconds: TimeInterval = 3600


private enum FakeGroupFailure: Error {
    case failed
}


private enum FakeJoinOutcome {
    case succeed(room: String)
    case duplicate
    case fail
}


private enum FakeCheckOutcome {
    case presentAll
    case presentNone
    case badRequest
    case groupCallInvalid
}


private let testParticipants: [LiveKitGroupParticipant] = [
    LiveKitGroupParticipant(
        peerKey: "u1",
        isSelf: true,
        videoEndpoint: "u1.9",
        presentationEndpoint: nil
    ),
    LiveKitGroupParticipant(
        peerKey: "u2",
        isSelf: false,
        videoEndpoint: "u2.7",
        presentationEndpoint: "u2.8.p"
    ),
]


private func joinParams(room: String) -> String {
    return "{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\",\"room\":\"\(room)\"}}"
}


/// A remote video track that has no SDK track behind it. Its identity is the only thing the tests compare.
private final class FakeGroupRemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    var sdkTrack: RemoteVideoTrack? {
        return nil
    }
}


/// A remote video publication of a fake participant. It records the enable flags and the qualities it receives.
private final class FakeGroupRemotePublication: LiveKitGroupRemotePublication, @unchecked Sendable {
    let videoTrack: LiveKitGroupRemoteVideoTrack?
    private(set) var enabledCalls: [Bool] = []
    private(set) var qualityCalls: [LiveKitGroupVideoQuality] = []


    init(videoTrack: LiveKitGroupRemoteVideoTrack? = nil) {
        self.videoTrack = videoTrack
    }


    func setEnabled(_ isEnabled: Bool) async throws {
        enabledCalls.append(isEnabled)
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
        qualityCalls.append(quality)
    }
}


/// A remote participant of a fake room with a fixed identity and fixed video publications.
private final class FakeGroupRemoteParticipant: LiveKitGroupRemoteParticipant {
    let identity: String?
    let videoPublications: [LiveKitGroupRemotePublication]


    init(
        identity: String?,
        videoPublications: [LiveKitGroupRemotePublication]
    ) {
        self.identity = identity
        self.videoPublications = videoPublications
    }
}


/// A finite fake room session. It records the join parameters and the disconnects, and fails to connect when told to.
private final class FakeGroupRoomSession: LiveKitGroupRoomSession, @unchecked Sendable {
    var media: LiveKitRoomMedia? {
        return fakeMedia
    }


    let remoteParticipants: [LiveKitGroupRemoteParticipant]
    private let lock: NSLock = NSLock()
    private let connectSucceeds: Bool
    private let fakeMedia: LiveKitRoomMedia?
    private var recordedUrl: String?
    private var recordedToken: String?
    private var recordedDisconnects: Int = 0


    init(
        connectSucceeds: Bool,
        media: LiveKitRoomMedia?,
        remoteParticipants: [LiveKitGroupRemoteParticipant]
    ) {
        self.connectSucceeds = connectSucceeds
        self.fakeMedia = media
        self.remoteParticipants = remoteParticipants
    }


    var connectedUrl: String? {
        return read { () -> String? in
            return recordedUrl
        }
    }


    var connectedToken: String? {
        return read { () -> String? in
            return recordedToken
        }
    }


    var disconnectCount: Int {
        return read { () -> Int in
            return recordedDisconnects
        }
    }


    func connect(url: String, token: String) async throws {
        try recordConnect(url: url, token: token)
    }


    func disconnect() async {
        recordDisconnect()
    }


    private func recordConnect(url: String, token: String) throws {
        lock.lock()
        recordedUrl = url
        recordedToken = token
        lock.unlock()
        if !connectSucceeds {
            throw FakeGroupFailure.failed
        }
    }


    private func recordDisconnect() {
        lock.lock()
        recordedDisconnects += 1
        lock.unlock()
    }


    private func read<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


/// The fake group backend. It answers joins and checks from finite scripts and records every request and room.
private final class FakeGroupBackend: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let connectSucceeds: Bool
    private let media: LiveKitRoomMedia?
    private let remoteParticipants: [LiveKitGroupRemoteParticipant]
    private var joinOutcomes: [FakeJoinOutcome]
    private var checkOutcomes: [FakeCheckOutcome]
    private var recordedJoins: [(payload: String, isPresentation: Bool)] = []
    private var recordedSessions: [FakeGroupRoomSession] = []
    private var recordedSinks: [LiveKitGroupRoomEventSink] = []
    private var recordedLeaves: Int = 0
    private var recordedScreenUnpublishedAtLeave: Bool = false


    init(
        joinOutcomes: [FakeJoinOutcome],
        checkOutcomes: [FakeCheckOutcome] = [],
        connectSucceeds: Bool = true,
        media: LiveKitRoomMedia? = nil,
        remoteParticipants: [LiveKitGroupRemoteParticipant] = []
    ) {
        self.joinOutcomes = joinOutcomes
        self.checkOutcomes = checkOutcomes
        self.connectSucceeds = connectSucceeds
        self.media = media
        self.remoteParticipants = remoteParticipants
    }


    var joins: [(payload: String, isPresentation: Bool)] {
        return read { () -> [(payload: String, isPresentation: Bool)] in
            return recordedJoins
        }
    }


    var sessions: [FakeGroupRoomSession] {
        return read { () -> [FakeGroupRoomSession] in
            return recordedSessions
        }
    }


    var sinks: [LiveKitGroupRoomEventSink] {
        return read { () -> [LiveKitGroupRoomEventSink] in
            return recordedSinks
        }
    }


    var leaveCount: Int {
        return read { () -> Int in
            return recordedLeaves
        }
    }


    /// Whether the screen share was already unpublished when the presentation leave was sent.
    var screenUnpublishedAtLeave: Bool {
        return read { () -> Bool in
            return recordedScreenUnpublishedAtLeave
        }
    }


    func join(
        payload: String,
        isPresentation: Bool
    ) throws -> LiveKitGroupJoinResponse {
        return try read { () throws -> LiveKitGroupJoinResponse in
            recordedJoins.append((payload: payload, isPresentation: isPresentation))
            guard !joinOutcomes.isEmpty else {
                throw LiveKitGroupJoinError.serverError("No scripted join answer")
            }
            switch joinOutcomes.removeFirst() {
            case .succeed(let room):
                return LiveKitGroupJoinResponse(
                    params: joinParams(room: room),
                    participants: testParticipants
                )

            case .duplicate:
                throw LiveKitGroupJoinError.ssrcDuplicateMuch

            case .fail:
                throw LiveKitGroupJoinError.serverError("GROUPCALL_FAILED")
            }
        }
    }


    func check(sources: [UInt32]) throws -> [UInt32] {
        return try read { () throws -> [UInt32] in
            guard !checkOutcomes.isEmpty else {
                throw LiveKitGroupCheckError.other
            }
            switch checkOutcomes.removeFirst() {
            case .presentAll:
                return sources

            case .presentNone:
                return []

            case .badRequest:
                throw LiveKitGroupCheckError.badRequest

            case .groupCallInvalid:
                throw LiveKitGroupCheckError.groupCallInvalid
            }
        }
    }


    func makeSession(sink: LiveKitGroupRoomEventSink) -> LiveKitGroupRoomSession {
        return read { () -> LiveKitGroupRoomSession in
            let session: FakeGroupRoomSession = FakeGroupRoomSession(
                connectSucceeds: connectSucceeds,
                media: media,
                remoteParticipants: remoteParticipants
            )
            recordedSessions.append(session)
            recordedSinks.append(sink)
            return session
        }
    }


    func recordLeave() {
        read { () -> Void in
            recordedLeaves += 1
            if let fakeMedia: FakeLiveKitRoomMedia = media as? FakeLiveKitRoomMedia {
                recordedScreenUnpublishedAtLeave = fakeMedia.calls.contains(.unpublishScreenShare)
            }
        }
    }


    private func read<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}


/// Hands out distinct, increasing sources, so each join carries new sources.
/// The audio level timer waits an hour, so a test samples the levels only through `tickAudioLevels()`.
@MainActor
private func makeContext(
    backend: FakeGroupBackend,
    pollIntervalSeconds: TimeInterval = testPollIntervalSeconds,
    audioLevelClock: LiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
) -> LiveKitGroupCallContext {
    var lastSource: UInt32 = 100
    let nextSource: () -> UInt32 = { () -> UInt32 in
        lastSource += 1
        return lastSource
    }
    let joinRequest: LiveKitGroupJoinFunction = { (payload: String, isPresentation: Bool) async throws -> LiveKitGroupJoinResponse in
        return try backend.join(payload: payload, isPresentation: isPresentation)
    }
    let checkRequest: LiveKitGroupCheckFunction = { (sources: [UInt32]) async throws -> [UInt32] in
        return try backend.check(sources: sources)
    }
    let leavePresentationRequest: LiveKitGroupLeaveFunction = { () async -> Void in
        backend.recordLeave()
    }
    let makeSession: LiveKitGroupRoomSessionFactory = { (sink: LiveKitGroupRoomEventSink) -> LiveKitGroupRoomSession in
        return backend.makeSession(sink: sink)
    }
    let makeAudioMeter: () -> LiveKitAudioLevelMeter = { () -> LiveKitAudioLevelMeter in
        return FakeLiveKitAudioLevelMeter(level: testAudioLevel)
    }
    return LiveKitGroupCallContext(
        callId: testGroupCallId,
        joinRequest: joinRequest,
        checkRequest: checkRequest,
        leavePresentationRequest: leavePresentationRequest,
        pollIntervalSeconds: pollIntervalSeconds,
        nextSource: nextSource,
        makeSession: makeSession,
        audioLevelClock: audioLevelClock,
        makeAudioMeter: makeAudioMeter,
        audioLevelIntervalSeconds: testAudioLevelIntervalSeconds
    )
}


/// The microphone identifiers the fake room media received, in order.
private func recordedInputDeviceIds(_ media: FakeLiveKitRoomMedia) -> [String] {
    var deviceIds: [String] = []
    for call: FakeLiveKitRoomMediaCall in media.calls {
        if case let .setAudioInputDevice(deviceId) = call {
            deviceIds.append(deviceId)
        }
    }
    return deviceIds
}


/// The speaker identifiers the fake room media received, in order.
private func recordedOutputDeviceIds(_ media: FakeLiveKitRoomMedia) -> [String] {
    var deviceIds: [String] = []
    for call: FakeLiveKitRoomMediaCall in media.calls {
        if case let .setAudioOutputDevice(deviceId) = call {
            deviceIds.append(deviceId)
        }
    }
    return deviceIds
}


/// Polls a condition for a bounded number of steps and reports whether it became true.
@MainActor
private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<testWaitAttempts {
        if predicate() {
            return true
        }
        try? await Task.sleep(nanoseconds: testWaitStepNanoseconds)
    }
    return predicate()
}


/// Returns the connection SSRC followed by every source of every group in the payload.
private func sourcesOf(payload: String) throws -> [Int] {
    let parsed: Any = try JSONSerialization.jsonObject(with: Data(payload.utf8), options: [])
    let object: [String: Any] = try XCTUnwrap(parsed as? [String: Any])
    let ssrc: Int = try XCTUnwrap(object["ssrc"] as? Int)
    let groups: [[String: Any]] = try XCTUnwrap(object["ssrc-groups"] as? [[String: Any]])
    var sources: [Int] = [ssrc]
    for group: [String: Any] in groups {
        let groupSources: [Int] = try XCTUnwrap(group["sources"] as? [Int])
        sources.append(contentsOf: groupSources)
    }
    return sources
}


@MainActor
final class LiveKitGroupCallContextTests: XCTestCase {
    func testMainPayloadMatchesGroupJoinShape() {
        let values: [UInt32] = [1, 1, 0, 2, 3, 4, 5, 6, 7, 8]
        var index: Int = 0
        let payload: LiveKitGroupJoinPayload = LiveKitGroupJoinPayload.make(
            isPresentation: false,
            nextSource: { () -> UInt32 in
                let value: UInt32 = values[index]
                index += 1
                return value
            }
        )
        XCTAssertEqual(payload.ssrc, 1)
        XCTAssertEqual(
            payload.json,
            "{\"ssrc\":1,\"ssrc-groups\":[{\"semantics\":\"SIM\",\"sources\":[2,3,4]},{\"semantics\":\"FID\",\"sources\":[2,5]},{\"semantics\":\"FID\",\"sources\":[3,6]},{\"semantics\":\"FID\",\"sources\":[4,7]}]}"
        )
    }


    func testPresentationPayloadMatchesGroupJoinShape() {
        let values: [UInt32] = [10, 11, 12]
        var index: Int = 0
        let payload: LiveKitGroupJoinPayload = LiveKitGroupJoinPayload.make(
            isPresentation: true,
            nextSource: { () -> UInt32 in
                let value: UInt32 = values[index]
                index += 1
                return value
            }
        )
        XCTAssertEqual(payload.ssrc, 10)
        XCTAssertEqual(
            payload.json,
            "{\"ssrc\":10,\"ssrc-groups\":[{\"semantics\":\"FID\",\"sources\":[11,12]}]}"
        )
    }


    func testRandomPayloadsHaveDistinctNonZeroSources() throws {
        for _ in 0..<20 {
            let payload: LiveKitGroupJoinPayload = LiveKitGroupJoinPayload.make(
                isPresentation: false,
                nextSource: { () -> UInt32 in
                    return UInt32.random(in: 1...UInt32.max)
                }
            )
            let sources: [Int] = try sourcesOf(payload: payload.json)
            XCTAssertEqual(sources.count, 7)
            XCTAssertEqual(Set(sources).count, 7)
            XCTAssertFalse(sources.contains(0))
        }
    }


    func testStartJoinsMainConnectionAndConnectsRoom() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.77")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        var reported: [LiveKitGroupCallState] = []
        context.onStateChanged = { (newState: LiveKitGroupCallState) -> Void in
            reported.append(newState)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertEqual(backend.joins.count, 1)
        XCTAssertFalse(backend.joins[0].isPresentation)
        XCTAssertEqual(backend.sessions.count, 1)
        XCTAssertEqual(backend.sessions[0].connectedUrl, testUrl)
        XCTAssertEqual(backend.sessions[0].connectedToken, testToken)
        XCTAssertEqual(reported, [.connected])
        XCTAssertEqual(context.remoteEndpoints, ["u2.7", "u2.8.p"])
        context.stop()
    }


    func testJoinedRoomMustBelongToThisGroupCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.78")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.joinFailed)
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(backend.sessions.count, 0)
    }


    func testServerJoinErrorEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.fail])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.joinFailed)
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(backend.sessions.count, 0)
    }


    func testConnectFailureEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            connectSucceeds: false
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.connectionFailed)
        }
        XCTAssertTrue(ended)
    }


    func testDuplicateSourcesRegenerateAndJoinAgain() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.duplicate, .duplicate, .succeed(room: "g.77")]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertEqual(backend.joins.count, 3)
        XCTAssertNotEqual(backend.joins[0].payload, backend.joins[1].payload)
        XCTAssertNotEqual(backend.joins[1].payload, backend.joins[2].payload)
        context.stop()
    }


    func testRemoteEndpointsFollowParticipantUpdates() {
        let context: LiveKitGroupCallContext = makeContext(backend: FakeGroupBackend(joinOutcomes: []))
        context.updateParticipants([
            LiveKitGroupParticipant(
                peerKey: "u3",
                isSelf: false,
                videoEndpoint: "u3.4",
                presentationEndpoint: nil
            ),
            LiveKitGroupParticipant(
                peerKey: "u1",
                isSelf: true,
                videoEndpoint: "u1.9",
                presentationEndpoint: nil
            ),
        ])
        XCTAssertEqual(context.remoteEndpoints, ["u3.4"])
        context.updateParticipants([
            LiveKitGroupParticipant(
                peerKey: "u3",
                isSelf: false,
                videoEndpoint: nil,
                presentationEndpoint: nil
            ),
        ])
        XCTAssertEqual(context.remoteEndpoints, [])
    }


    func testStopEndsCallAndDisconnectsRoom() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.77")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.stop()
        XCTAssertEqual(context.state, .ended(.hungUp))
        let disconnected: Bool = await waitUntil { () -> Bool in
            return backend.sessions[0].disconnectCount == 1
        }
        XCTAssertTrue(disconnected)
    }


    func testHardDisconnectEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.77")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        backend.sinks[0].roomDidDisconnectUnexpectedly()
        XCTAssertEqual(context.state, .ended(.disconnected))
    }


    func testRoomConnectionFailureEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.77")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        backend.sinks[0].roomDidFailToConnect()
        XCTAssertEqual(context.state, .ended(.connectionFailed))
    }


    func testEvictionRejoinsMainConnectionWithFreshSources() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            checkOutcomes: [.presentNone]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let rejoined: Bool = await waitUntil { () -> Bool in
            return backend.joins.count == 2 && backend.sessions.count == 2 && backend.sessions[0].disconnectCount == 1
        }
        XCTAssertTrue(rejoined)
        XCTAssertNotEqual(backend.joins[0].payload, backend.joins[1].payload)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testBadRequestFromCheckRejoinsMainConnection() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            checkOutcomes: [.badRequest]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let rejoined: Bool = await waitUntil { () -> Bool in
            return backend.joins.count == 2 && backend.sessions.count == 2
        }
        XCTAssertTrue(rejoined)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testGroupCallInvalidFromCheckEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            checkOutcomes: [.groupCallInvalid]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.groupCallInvalid)
        }
        XCTAssertTrue(ended)
    }


    func testPresentationNeedsConnectedCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [.succeed(room: "g.77")])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        XCTAssertEqual(backend.joins.count, 0)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertEqual(backend.joins.count, 1)
        context.stop()
    }


    func testPresentationJoinsSecondRoomAndLeavesOnStop() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let presenting: Bool = await waitUntil { () -> Bool in
            return context.isPresentationActive
        }
        XCTAssertTrue(presenting)
        XCTAssertEqual(backend.joins.count, 2)
        XCTAssertTrue(backend.joins[1].isPresentation)
        XCTAssertTrue(backend.joins[1].payload.contains("\"semantics\":\"FID\""))
        XCTAssertFalse(backend.joins[1].payload.contains("SIM"))
        XCTAssertEqual(backend.sessions.count, 2)
        XCTAssertEqual(backend.sessions[1].connectedUrl, testUrl)
        context.stopPresentation()
        XCTAssertFalse(context.isPresentationActive)
        let left: Bool = await waitUntil { () -> Bool in
            return backend.leaveCount == 1 && backend.sessions[1].disconnectCount == 1
        }
        XCTAssertTrue(left)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testRefusedPresentationKeepsCallAlive() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .fail]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let refused: Bool = await waitUntil { () -> Bool in
            return backend.joins.count == 2 && backend.leaveCount == 1
        }
        XCTAssertTrue(refused)
        XCTAssertFalse(context.isPresentationActive)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testPresentationRoomDisconnectEndsCall() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let presenting: Bool = await waitUntil { () -> Bool in
            return context.isPresentationActive
        }
        XCTAssertTrue(presenting)
        backend.sinks[1].roomDidDisconnectUnexpectedly()
        XCTAssertEqual(context.state, .ended(.disconnected))
    }


    func testRoomsWithoutMediaExposeNoMedia() async throws {
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")]
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertNil(context.mainMedia)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let presenting: Bool = await waitUntil { () -> Bool in
            return context.isPresentationActive
        }
        XCTAssertTrue(presenting)
        XCTAssertNil(context.presentationMedia)
        context.stop()
    }


    func testMediaOfEachRoomIsExposedWhileItLives() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertTrue(context.mainMedia === media)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let presenting: Bool = await waitUntil { () -> Bool in
            return context.isPresentationActive
        }
        XCTAssertTrue(presenting)
        XCTAssertTrue(context.presentationMedia === media)
        context.stopPresentation()
        XCTAssertNil(context.presentationMedia)
        XCTAssertTrue(context.mainMedia === media)
        context.stop()
        XCTAssertNil(context.mainMedia)
        XCTAssertNil(context.presentationMedia)
    }


    func testPresentationPublishesTrackOnlyAfterItsRoomConnects() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.publishScreenShare)
        }
        XCTAssertTrue(published)
        XCTAssertEqual(backend.joins.count, 2)
        XCTAssertEqual(backend.sessions.count, 2)
        XCTAssertTrue(context.isPresentationActive)
        context.stop()
    }


    func testStopPresentationUnpublishesScreenShareBeforeLeaving() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.publishScreenShare)
        }
        XCTAssertTrue(published)
        context.stopPresentation()
        let unpublished: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.unpublishScreenShare) && backend.leaveCount == 1
        }
        XCTAssertTrue(unpublished)
        XCTAssertTrue(backend.screenUnpublishedAtLeave)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testScreenPublishFailureStopsPresentationAndKeepsCall() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        media.errorToThrow = FakeGroupFailure.failed
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let left: Bool = await waitUntil { () -> Bool in
            return backend.leaveCount == 1
        }
        XCTAssertTrue(left)
        XCTAssertFalse(context.isPresentationActive)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testCameraSetBeforeJoinPublishesWhenMainConnects() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.setCamera(track: FakeLiveKitLocalVideoTrack())
        XCTAssertTrue(media.calls.isEmpty)
        context.start()
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.publishCamera)
        }
        XCTAssertTrue(published)
        XCTAssertEqual(media.calls.filter { (call: FakeLiveKitRoomMediaCall) -> Bool in
            return call == .publishCamera
        }.count, 1)
        XCTAssertEqual(backend.joins.count, 1)
        context.stop()
    }


    func testCameraSetWhileConnectedPublishesAtOnce() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.setCamera(track: FakeLiveKitLocalVideoTrack())
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.publishCamera)
        }
        XCTAssertTrue(published)
        context.stop()
    }


    func testDisableCameraMutesMainCamera() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.setCamera(track: FakeLiveKitLocalVideoTrack())
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.publishCamera)
        }
        XCTAssertTrue(published)
        context.disableCamera()
        let muted: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setCameraEnabled(false))
        }
        XCTAssertTrue(muted)
        context.stop()
    }


    func testCameraIsPublishedAgainAfterRejoin() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            checkOutcomes: [.presentNone],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.setCamera(track: FakeLiveKitLocalVideoTrack())
        context.start()
        let republished: Bool = await waitUntil { () -> Bool in
            return media.calls.filter { (call: FakeLiveKitRoomMediaCall) -> Bool in
                return call == .publishCamera
            }.count == 2
        }
        XCTAssertTrue(republished)
        XCTAssertEqual(backend.joins.count, 2)
        context.stop()
    }


    func testMicrophoneIsPublishedMutedByDefault() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        XCTAssertTrue(context.isMuted)
        context.start()
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(false))
        }
        XCTAssertTrue(published)
        XCTAssertFalse(media.calls.contains(.setMicrophoneEnabled(true)))
        XCTAssertTrue(context.isMuted)
        context.stop()
    }


    func testPostedMuteCommandsApplyInOrderAndEndMuted() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        var reported: [Bool] = []
        context.onMutedChanged = { (muted: Bool) -> Void in
            reported.append(muted)
        }
        context.start()
        let initialMuteApplied: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(false))
        }
        XCTAssertTrue(initialMuteApplied)
        let callsBeforePosts: Int = media.calls.count
        context.post(.setMuted(true))
        context.post(.setMuted(false))
        context.post(.setMuted(true))
        let applied: Bool = await waitUntil { () -> Bool in
            return media.calls.count > callsBeforePosts
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(reported, [false, true])
        XCTAssertTrue(context.isMuted)
        XCTAssertEqual(media.calls.last, FakeLiveKitRoomMediaCall.setMicrophoneEnabled(false))
        context.stop()
    }


    func testMuteSetBeforeConnectAppliesOnConnect() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.setMuted(false)
        XCTAssertFalse(context.isMuted)
        XCTAssertTrue(media.calls.isEmpty)
        context.start()
        let published: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(true))
        }
        XCTAssertTrue(published)
        XCTAssertFalse(media.calls.contains(.setMicrophoneEnabled(false)))
        context.stop()
    }


    func testSetMutedWhileConnectedAppliesAtOnceAndReports() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        var reported: [Bool] = []
        context.onMutedChanged = { (muted: Bool) -> Void in
            reported.append(muted)
        }
        context.start()
        let initialMuteApplied: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(false))
        }
        XCTAssertTrue(initialMuteApplied)
        context.setMuted(false)
        XCTAssertEqual(reported, [false])
        XCTAssertFalse(context.isMuted)
        let unmuted: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(true))
        }
        XCTAssertTrue(unmuted)
        context.stop()
    }


    func testInputDeviceSelectedBeforeConnectIsAppliedOnConnect() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.switchAudioInput("mic-early")
        XCTAssertTrue(media.calls.isEmpty)
        context.start()
        let applied: Bool = await waitUntil { () -> Bool in
            return recordedInputDeviceIds(media).contains("mic-early")
        }
        XCTAssertTrue(applied)
        context.stop()
    }


    func testOutputDeviceSelectedBeforeConnectIsAppliedOnConnect() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.switchAudioOutput("speaker-early")
        context.start()
        let applied: Bool = await waitUntil { () -> Bool in
            return recordedOutputDeviceIds(media).contains("speaker-early")
        }
        XCTAssertTrue(applied)
        context.stop()
    }


    func testInputDeviceSwitchWhileConnectedAppliesAtOnce() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let connected: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(false))
        }
        XCTAssertTrue(connected)
        context.switchAudioInput("mic-changed")
        let applied: Bool = await waitUntil { () -> Bool in
            return recordedInputDeviceIds(media).contains("mic-changed")
        }
        XCTAssertTrue(applied)
        context.stop()
    }


    func testLastInputDeviceSwitchWins() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let connected: Bool = await waitUntil { () -> Bool in
            return media.calls.contains(.setMicrophoneEnabled(false))
        }
        XCTAssertTrue(connected)
        context.switchAudioInput("mic-first")
        context.switchAudioInput("mic-last")
        let settled: Bool = await waitUntil { () -> Bool in
            return recordedInputDeviceIds(media).count >= 2
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(recordedInputDeviceIds(media).last, "mic-last")
        context.stop()
    }


    func testSwitchAfterStopIsIgnored() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.stop()
        context.switchAudioInput("mic-late")
        context.switchAudioOutput("speaker-late")
        try await Task.sleep(nanoseconds: testWaitStepNanoseconds * 5)
        XCTAssertTrue(recordedInputDeviceIds(media).isEmpty)
        XCTAssertTrue(recordedOutputDeviceIds(media).isEmpty)
    }


    func testNoiseSuppressionSettingSurvivesRejoin() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            checkOutcomes: [.badRequest],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.setNoiseSuppressionEnabled(false)
        XCTAssertFalse(context.isNoiseSuppressionEnabled)
        context.start()
        let appliedAfterRejoin: Bool = await waitUntil { () -> Bool in
            return backend.joins.count == 2 && media.calls.filter { (call: FakeLiveKitRoomMediaCall) -> Bool in
                return call == .setNoiseSuppressionEnabled(false)
            }.count >= 2
        }
        XCTAssertTrue(appliedAfterRejoin)
        XCTAssertFalse(context.isNoiseSuppressionEnabled)
        XCTAssertEqual(context.state, .connected)
        context.stop()
    }


    func testMicrophonePublishFailureEndsCallAsConnectionFailure() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        media.microphoneErrorToThrow = FakeGroupFailure.failed
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.connectionFailed)
        }
        XCTAssertTrue(ended)
        XCTAssertFalse(media.calls.contains(.setMicrophoneEnabled(true)))
    }


    func testCameraPublishFailureEndsCallAsConnectionFailure() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        media.cameraPublishErrorToThrow = FakeGroupFailure.failed
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.setCamera(track: FakeLiveKitLocalVideoTrack())
        context.start()
        let ended: Bool = await waitUntil { () -> Bool in
            return context.state == .ended(.connectionFailed)
        }
        XCTAssertTrue(ended)
        XCTAssertFalse(media.calls.contains(.publishCamera))
    }


    func testRemoteAudioTrackReportsItsSourceLevel() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let context: LiveKitGroupCallContext = makeContext(backend: backend, audioLevelClock: clock)
        var reported: [[(LiveKitGroupAudioLevelKey, Float, Bool)]] = []
        context.onAudioLevels = { (entries: [(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void in
            reported.append(entries)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        XCTAssertEqual(track.attachedMeterIdentifiers.count, 1)
        context.tickAudioLevels()
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported[0].map { (entry: (LiveKitGroupAudioLevelKey, Float, Bool)) -> LiveKitGroupAudioLevelKey in
            return entry.0
        }, [.source(7)])
        XCTAssertEqual(reported[0][0].1, testAudioLevel, accuracy: 0.0001)
        XCTAssertTrue(reported[0][0].2)
        context.stop()
    }


    func testLocalMicrophoneLevelIsZeroWhileMuted() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let context: LiveKitGroupCallContext = makeContext(backend: backend, audioLevelClock: clock)
        var reported: [[(LiveKitGroupAudioLevelKey, Float, Bool)]] = []
        context.onAudioLevels = { (entries: [(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void in
            reported.append(entries)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertTrue(context.isMuted)
        let local: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u1.9", isLocal: true)
        media.onAudioTrackAvailable?(local)
        context.tickAudioLevels()
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported[0][0].0, .local)
        XCTAssertEqual(reported[0][0].1, 0)
        XCTAssertFalse(reported[0][0].2)

        context.setMuted(false)
        clock.milliseconds = 100
        context.tickAudioLevels()
        XCTAssertEqual(reported.count, 2)
        XCTAssertEqual(reported[1][0].0, .local)
        XCTAssertEqual(reported[1][0].1, testAudioLevel, accuracy: 0.0001)
        XCTAssertTrue(reported[1][0].2)
        context.stop()
    }


    func testRemovedAudioTrackIsDetachedAndNoLongerReported() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let context: LiveKitGroupCallContext = makeContext(backend: backend, audioLevelClock: clock)
        var reported: [[(LiveKitGroupAudioLevelKey, Float, Bool)]] = []
        context.onAudioLevels = { (entries: [(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void in
            reported.append(entries)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        context.tickAudioLevels()
        XCTAssertEqual(reported.last?.count, 1)

        media.onAudioTrackRemoved?(track)
        XCTAssertEqual(track.detachedMeterIdentifiers, track.attachedMeterIdentifiers)
        clock.milliseconds = 100
        context.tickAudioLevels()
        XCTAssertEqual(reported.last?.count, 0)
        context.stop()
    }


    func testUnidentifiedAudioTrackIsNotMetered() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "bogus", isLocal: false)
        media.onAudioTrackAvailable?(track)
        XCTAssertTrue(track.attachedMeterIdentifiers.isEmpty)
        context.stop()
    }


    func testPresentationAudioTrackReportsItsSourceLevel() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77"), .succeed(room: "g.77")],
            media: media
        )
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let context: LiveKitGroupCallContext = makeContext(backend: backend, audioLevelClock: clock)
        var reported: [[(LiveKitGroupAudioLevelKey, Float, Bool)]] = []
        context.onAudioLevels = { (entries: [(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void in
            reported.append(entries)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.startPresentation(track: FakeLiveKitLocalVideoTrack())
        let presenting: Bool = await waitUntil { () -> Bool in
            return context.isPresentationActive
        }
        XCTAssertTrue(presenting)
        // The fake media is shared by both rooms, so the presentation room binds its callbacks last.
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.8.p", isLocal: false)
        media.onAudioTrackAvailable?(track)
        context.tickAudioLevels()
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported[0].map { (entry: (LiveKitGroupAudioLevelKey, Float, Bool)) -> LiveKitGroupAudioLevelKey in
            return entry.0
        }, [.source(8)])
        context.stop()
    }


    func testZeroVolumeMutesTheRemoteTrackOfItsSource() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        context.setVolume(ssrc: 7, volume: 0)
        XCTAssertEqual(track.playbackVolumes, [0])
        context.stop()
    }


    func testVolumeSetBeforeTheTrackAppearsIsAppliedWhenItAppears() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.setVolume(ssrc: 7, volume: 0.5)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        XCTAssertEqual(track.playbackVolumes, [0.5])
        context.stop()
    }


    func testVolumeOfOtherSourceAndLocalMicrophoneAreNotChanged() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let other: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.8", isLocal: false)
        let local: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u1.9", isLocal: true)
        media.onAudioTrackAvailable?(other)
        media.onAudioTrackAvailable?(local)
        context.setVolume(ssrc: 7, volume: 0)
        XCTAssertTrue(other.playbackVolumes.isEmpty)
        XCTAssertTrue(local.playbackVolumes.isEmpty)
        context.stop()
    }


    func testVolumeIsClampedToTheLiveKitRange() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        context.setVolume(ssrc: 7, volume: 25)
        XCTAssertEqual(track.playbackVolumes, [10])
        context.stop()
    }


    func testRemovedParticipantClearsItsEndpoints() {
        let backend: FakeGroupBackend = FakeGroupBackend(joinOutcomes: [])
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.updateParticipants(testParticipants)
        XCTAssertEqual(context.remoteEndpoints, ["u2.7", "u2.8.p"])
        context.updateParticipants([
            LiveKitGroupParticipant(
                peerKey: "u2",
                isSelf: false,
                videoEndpoint: nil,
                presentationEndpoint: nil
            ),
        ])
        XCTAssertTrue(context.remoteEndpoints.isEmpty)
    }


    func testRequestedChannelIsEnabledAndUnrequestedPublicationIsDisabled() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let requested: FakeGroupRemotePublication = FakeGroupRemotePublication()
        let unrequested: FakeGroupRemotePublication = FakeGroupRemotePublication()
        let remoteParticipants: [LiveKitGroupRemoteParticipant] = [
            FakeGroupRemoteParticipant(identity: "u2.7", videoPublications: [requested]),
            FakeGroupRemoteParticipant(identity: "u3.5", videoPublications: [unrequested]),
        ]
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media,
            remoteParticipants: remoteParticipants
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let disabledOnConnect: Bool = await waitUntil { () -> Bool in
            return unrequested.enabledCalls == [false]
        }
        XCTAssertTrue(disabledOnConnect)
        context.setRequestedVideoChannels([
            LiveKitGroupVideoRequest(
                endpoint: "u2.7",
                quality: .medium,
                isVisible: true
            ),
        ])
        let applied: Bool = await waitUntil { () -> Bool in
            return requested.qualityCalls == [.medium] && unrequested.enabledCalls == [false, false]
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(requested.enabledCalls, [false, true])
        XCTAssertEqual(unrequested.enabledCalls, [false, false])
        XCTAssertTrue(unrequested.qualityCalls.isEmpty)
        context.stop()
    }


    func testRemoteVideoTrackResolvesEndpointAndFollowsRoomChanges() async throws {
        let presentationTrack: FakeGroupRemoteVideoTrack = FakeGroupRemoteVideoTrack()
        let cameraTrack: FakeGroupRemoteVideoTrack = FakeGroupRemoteVideoTrack()
        let remoteParticipants: [LiveKitGroupRemoteParticipant] = [
            FakeGroupRemoteParticipant(identity: "u2.8.p", videoPublications: [FakeGroupRemotePublication(videoTrack: presentationTrack)]),
            FakeGroupRemoteParticipant(identity: "u4.7", videoPublications: [FakeGroupRemotePublication(videoTrack: cameraTrack)]),
            FakeGroupRemoteParticipant(identity: "u3.5", videoPublications: [FakeGroupRemotePublication()]),
        ]
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            remoteParticipants: remoteParticipants
        )
        let context: LiveKitGroupCallContext = makeContext(backend: backend)
        var changes: Int = 0
        context.onRemoteTracksChanged = { () -> Void in
            changes += 1
        }
        XCTAssertNil(context.remoteVideoTrack(endpoint: "u2.8.p"))
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertTrue(context.remoteVideoTrack(endpoint: "u2.8.p") === presentationTrack)
        XCTAssertTrue(context.remoteVideoTrack(endpoint: "u4.7") === cameraTrack)
        XCTAssertNil(context.remoteVideoTrack(endpoint: "u3.5"))
        XCTAssertNil(context.remoteVideoTrack(endpoint: "u9.1"))
        backend.sinks[0].roomRemoteTracksDidChange()
        XCTAssertEqual(changes, 1)
        context.stop()
        XCTAssertNil(context.remoteVideoTrack(endpoint: "u2.8.p"))
        XCTAssertNil(context.remoteVideoTrack(endpoint: "u4.7"))
        XCTAssertEqual(changes, 2)
    }


    func testEndedCallDetachesTracksAndReportsNoLevels() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let backend: FakeGroupBackend = FakeGroupBackend(
            joinOutcomes: [.succeed(room: "g.77")],
            media: media
        )
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let context: LiveKitGroupCallContext = makeContext(backend: backend, audioLevelClock: clock)
        var reported: [[(LiveKitGroupAudioLevelKey, Float, Bool)]] = []
        context.onAudioLevels = { (entries: [(LiveKitGroupAudioLevelKey, Float, Bool)]) -> Void in
            reported.append(entries)
        }
        context.start()
        let reachedConnected: Bool = await waitUntil { () -> Bool in
            return context.state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let track: FakeLiveKitAudioTrackHandle = FakeLiveKitAudioTrackHandle(participantIdentity: "u2.7", isLocal: false)
        media.onAudioTrackAvailable?(track)
        context.stop()
        XCTAssertEqual(track.detachedMeterIdentifiers, track.attachedMeterIdentifiers)
        clock.milliseconds = 100
        context.tickAudioLevels()
        XCTAssertTrue(reported.isEmpty)
    }
}
