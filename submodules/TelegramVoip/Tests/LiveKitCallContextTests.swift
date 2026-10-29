import XCTest
import LiveKit
@testable import TelegramVoip


private let testToken: String = "bearer-secret-token-value"
private let testUrl: String = "wss://project.livekit.cloud"
private let testCallId: Int64 = 42
private let testWaitAttempts: Int = 200
private let testWaitStepNanoseconds: UInt64 = 10_000_000
private let testHangNanoseconds: UInt64 = 5_000_000_000


private enum FakeFailure: Error {
    case failed
}


private enum FakeBehavior {
    case succeed
    case fail
    case hang
}


/// The media calls that the fake room records, in the order they were made.
private enum FakeMediaCall: Equatable {
    case microphone(Bool)
    case noiseSuppression(Bool)
    case camera(Bool)
    case publishCamera
    case publishScreenShare
    case unpublishScreenShare
    case audioInput(String)
    case audioOutput(String)
}


private final class FakeLocalVideoTrack: LiveKitLocalVideoTrack {
    var sdkTrack: LocalVideoTrack? {
        return nil
    }
}


private final class FakeRemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    var sdkTrack: RemoteVideoTrack? {
        return nil
    }
}


private final class FakeRemotePublication: LiveKitGroupRemotePublication {
    let videoTrack: LiveKitGroupRemoteVideoTrack?


    init(videoTrack: LiveKitGroupRemoteVideoTrack?) {
        self.videoTrack = videoTrack
    }


    func setEnabled(_ isEnabled: Bool) async throws {
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
    }
}


private final class FakeRemoteParticipant: LiveKitGroupRemoteParticipant {
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


/// A finite fake room session. A hang sleeps for a bounded time and throws when the caller cancels it.
private final class FakeLiveKitRoomSession: LiveKitCallRoomSession, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let connectBehavior: FakeBehavior
    private let disconnectBehavior: FakeBehavior
    private var recordedUrl: String?
    private var recordedToken: String?
    private var recordedDisconnects: Int = 0
    private var recordedMediaCalls: [FakeMediaCall] = []
    private var fakeRemoteParticipants: [LiveKitGroupRemoteParticipant] = []


    init(
        connectBehavior: FakeBehavior,
        disconnectBehavior: FakeBehavior
    ) {
        self.connectBehavior = connectBehavior
        self.disconnectBehavior = disconnectBehavior
    }


    var connectedUrl: String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedUrl
    }


    var connectedToken: String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedToken
    }


    var disconnectCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedDisconnects
    }


    var mediaCalls: [FakeMediaCall] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedMediaCalls
    }


    var remoteParticipants: [LiveKitGroupRemoteParticipant] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return fakeRemoteParticipants
    }


    func setRemoteParticipants(_ participants: [LiveKitGroupRemoteParticipant]) {
        lock.lock()
        fakeRemoteParticipants = participants
        lock.unlock()
    }


    func connect(url: String, token: String) async throws {
        lock.lock()
        recordedUrl = url
        recordedToken = token
        lock.unlock()
        try await run(connectBehavior)
    }


    func disconnect() async {
        lock.lock()
        recordedDisconnects += 1
        lock.unlock()
        try? await run(disconnectBehavior)
    }


    func setMicrophoneEnabled(_ isEnabled: Bool) async throws {
        record(.microphone(isEnabled))
    }


    func setNoiseSuppressionEnabled(_ isEnabled: Bool) async throws {
        record(.noiseSuppression(isEnabled))
    }


    func setCameraEnabled(_ isEnabled: Bool) async throws {
        record(.camera(isEnabled))
    }


    func publishCamera(_ track: LiveKitLocalVideoTrack) async throws {
        record(.publishCamera)
    }


    func publishScreenShare(_ track: LiveKitLocalVideoTrack) async throws {
        record(.publishScreenShare)
    }


    func unpublishScreenShare() async throws {
        record(.unpublishScreenShare)
    }


    func setAudioInputDevice(id: String) async throws {
        record(.audioInput(id))
    }


    func setAudioOutputDevice(id: String) async throws {
        record(.audioOutput(id))
    }


    private func record(_ call: FakeMediaCall) {
        lock.lock()
        recordedMediaCalls.append(call)
        lock.unlock()
    }


    private func run(_ behavior: FakeBehavior) async throws {
        switch behavior {
        case .succeed:
            return

        case .fail:
            throw FakeFailure.failed

        case .hang:
            try await Task.sleep(nanoseconds: testHangNanoseconds)
        }
    }
}


private func joinJson(
    url: String = testUrl,
    token: String = testToken,
    room: String = "p.42"
) -> String {
    return "{\"livekit\":{\"url\":\"\(url)\",\"token\":\"\(token)\",\"room\":\"\(room)\"}}"
}


private func authKey(length: Int) -> Data {
    return Data(repeating: 7, count: length)
}


@MainActor
private func makeContext(
    session: FakeLiveKitRoomSession,
    joinDeadline: TimeInterval = 5,
    leaveDeadline: TimeInterval = 5
) throws -> LiveKitCallContext {
    return try LiveKitCallContext(
        callId: testCallId,
        versions: [LiveKitCallContext.protocolName],
        parameters: joinJson(),
        authKey: authKey(length: 256),
        joinDeadline: joinDeadline,
        leaveDeadline: leaveDeadline,
        makeSession: { _, _ in session }
    )
}


/// Polls the state for a bounded number of steps and reports whether the predicate became true.
@MainActor
private func waitForState(
    _ context: LiveKitCallContext,
    matching predicate: (LiveKitCallState) -> Bool
) async -> Bool {
    for _ in 0..<testWaitAttempts {
        if predicate(context.state) {
            return true
        }
        try? await Task.sleep(nanoseconds: testWaitStepNanoseconds)
    }
    return predicate(context.state)
}


@MainActor
final class LiveKitCallContextTests: XCTestCase {
    func testKeyProviderMatchesOneToOneContract() throws {
        let provider: BaseKeyProvider = try LiveKitCallContext.makeKeyProvider(authKey: authKey(length: 256))
        XCTAssertTrue(provider.options.sharedKey)
        XCTAssertEqual(provider.options.ratchetWindowSize, 0)
        XCTAssertEqual(provider.options.ratchetSalt, Data("LKFrameEncryptionKey".utf8))
        XCTAssertEqual(provider.options.uncryptedMagicBytes, Data("LK-ROCKS".utf8))
        XCTAssertEqual(provider.options.failureTolerance, -1)
        XCTAssertEqual(provider.options.keyRingSize, 16)
        XCTAssertTrue(provider.options.discardFrameWhenCryptorNotReady)
        XCTAssertEqual(provider.options.keyDerivationAlgorithm, .hkdf)
        XCTAssertEqual(provider.getCurrentKeyIndex(), 0)
    }


    func testRejectsDhKeyThatIsNot256Bytes() {
        for length: Int in [0, 1, 255, 257] {
            XCTAssertThrowsError(try LiveKitCallContext.makeKeyProvider(authKey: authKey(length: length)), "length \(length)") { (error: Error) -> Void in
                XCTAssertEqual(error as? LiveKitCallContextError, .invalidAuthKey)
            }
        }
        XCTAssertNoThrow(try LiveKitCallContext.makeKeyProvider(authKey: authKey(length: 256)))
    }


    func testRejectsUnsupportedProtocol() {
        XCTAssertThrowsError(
            try LiveKitCallContext(
                callId: testCallId,
                versions: ["some-other-protocol"],
                parameters: joinJson(),
                authKey: authKey(length: 256),
                joinDeadline: 5,
                leaveDeadline: 5,
                makeSession: { _, _ in FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed) }
            )
        ) { (error: Error) -> Void in
            XCTAssertEqual(error as? LiveKitCallContextError, .unsupportedProtocol)
        }
    }


    func testRejectsRoomMismatchWithCanonicalErrorAndNoToken() {
        XCTAssertThrowsError(
            try LiveKitCallContext(
                callId: testCallId,
                versions: [LiveKitCallContext.protocolName],
                parameters: joinJson(room: "g.42"),
                authKey: authKey(length: 256),
                joinDeadline: 5,
                leaveDeadline: 5,
                makeSession: { _, _ in FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed) }
            )
        ) { (error: Error) -> Void in
            XCTAssertEqual(error.localizedDescription, "Invalid LiveKit join parameters for this call")
            XCTAssertFalse(error.localizedDescription.contains(testToken))
        }
    }


    func testStartConnectsWithJoinParametersAndReportsConnected() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        var reported: [LiveKitCallState] = []
        context.onStateChanged = { (newState: LiveKitCallState) -> Void in
            reported.append(newState)
        }
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertEqual(session.connectedUrl, testUrl)
        XCTAssertEqual(session.connectedToken, testToken)
        XCTAssertEqual(reported, [.connected])
    }


    func testConnectFailureEndsCall() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .fail, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.connectionFailed)
        }
        XCTAssertTrue(ended)
    }


    func testJoinDeadlineEndsCallAndDisconnects() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .hang, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session, joinDeadline: 0.05)
        context.start()
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.joinTimedOut)
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.disconnectCount, 1)
    }


    func testJoinDeadlineDoesNotEndConnectedCall() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session, joinDeadline: 0.05)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(context.state, .connected)
    }


    func testFailedEncryptionStateEndsCallButHealthyStateDoesNot() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.roomDidReportMediaEncryption(.healthy)
        XCTAssertEqual(context.state, .connected)
        context.roomDidReportMediaEncryption(.failed)
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.mediaEncryptionFailed)
        }
        XCTAssertTrue(ended)
    }


    func testEveryE2EEFailureStateIsFailedAndOkStatesAreHealthy() {
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .encryption_failed), .failed)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .decryption_failed), .failed)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .missing_key), .failed)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .internal_error), .failed)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .new), .healthy)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .ok), .healthy)
        XCTAssertEqual(LiveKitMediaEncryptionState(e2eeState: .key_ratcheted), .healthy)
    }


    func testUnexpectedDisconnectEndsCall() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.roomDidDisconnectUnexpectedly()
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.disconnected)
        }
        XCTAssertTrue(ended)
    }


    func testStopEndsCallOnceAndLeavesRoom() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.stop()
        context.stop()
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.hungUp)
        }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.disconnectCount, 1)
    }


    func testLeaveDeadlineReportsEndWhenDisconnectHangs() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .hang)
        let context: LiveKitCallContext = try makeContext(session: session, leaveDeadline: 0.05)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.stop()
        let ended: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.hungUp)
        }
        XCTAssertTrue(ended)
    }


    func testStopBeforeStartEndsCallWithoutConnecting() throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.stop()
        XCTAssertEqual(context.state, .ended(.hungUp))
        context.start()
        XCTAssertNil(session.connectedUrl)
    }


    func testMediaIsNilBeforeStart() throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        XCTAssertNil(context.media)
    }


    func testMediaRoutesLocalOperationsToRoomSession() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        guard let media: LiveKitCallMedia = context.media else {
            XCTFail("The media of a connected call is nil")
            return
        }
        try await media.setMicrophoneEnabled(false)
        try await media.setNoiseSuppressionEnabled(true)
        try await media.setCameraEnabled(true)
        try await media.publishScreenShare(FakeLocalVideoTrack())
        try await media.unpublishScreenShare()
        try await media.setAudioInputDevice(id: "input-device")
        try await media.setAudioOutputDevice(id: "output-device")
        XCTAssertEqual(session.mediaCalls, [
            .microphone(false),
            .noiseSuppression(true),
            .camera(true),
            .publishScreenShare,
            .unpublishScreenShare,
            .audioInput("input-device"),
            .audioOutput("output-device")
        ])
    }


    func testMediaExposesRemoteVideoOfRemoteParticipants() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let track: FakeRemoteVideoTrack = FakeRemoteVideoTrack()
        let publication: FakeRemotePublication = FakeRemotePublication(videoTrack: track)
        session.setRemoteParticipants([
            FakeRemoteParticipant(identity: "p.42", videoPublications: [publication])
        ])
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        let participants: [LiveKitGroupRemoteParticipant] = context.media?.remoteParticipants ?? []
        XCTAssertEqual(participants.count, 1)
        XCTAssertEqual(participants.first?.identity, "p.42")
        XCTAssertTrue(participants.first?.videoPublications.first?.videoTrack === track)
    }


    func testMediaPublishesCameraTrackToRoomSession() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        try await context.media?.publishCamera(FakeLocalVideoTrack())
        XCTAssertEqual(session.mediaCalls, [.publishCamera])
    }


    func testRemoteTrackChangeIsReportedOnlyWhileConnected() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        var changeCount: Int = 0
        context.onRemoteTracksChanged = {
            changeCount += 1
        }
        context.roomRemoteTracksDidChange()
        XCTAssertEqual(changeCount, 0)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.roomRemoteTracksDidChange()
        XCTAssertEqual(changeCount, 1)
        context.stop()
        context.roomRemoteTracksDidChange()
        XCTAssertEqual(changeCount, 1)
    }


    func testMediaUpdateFailureEndsCallWithConnectionFailure() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        context.failMediaUpdate()
        let reachedEnded: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .ended(.connectionFailed)
        }
        XCTAssertTrue(reachedEnded)
    }


    func testMediaIsNilOnceCallIsStopped() async throws {
        let session: FakeLiveKitRoomSession = FakeLiveKitRoomSession(connectBehavior: .succeed, disconnectBehavior: .succeed)
        let context: LiveKitCallContext = try makeContext(session: session)
        context.start()
        let reachedConnected: Bool = await waitForState(context) { (state: LiveKitCallState) -> Bool in
            return state == .connected
        }
        XCTAssertTrue(reachedConnected)
        XCTAssertNotNil(context.media)
        context.stop()
        XCTAssertNil(context.media)
    }
}
