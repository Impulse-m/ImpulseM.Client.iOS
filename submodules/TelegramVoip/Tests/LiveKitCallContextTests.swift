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


/// A finite fake room session. A hang sleeps for a bounded time and throws when the caller cancels it.
private final class FakeLiveKitRoomSession: LiveKitRoomSession, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let connectBehavior: FakeBehavior
    private let disconnectBehavior: FakeBehavior
    private var recordedUrl: String?
    private var recordedToken: String?
    private var recordedDisconnects: Int = 0


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
}
