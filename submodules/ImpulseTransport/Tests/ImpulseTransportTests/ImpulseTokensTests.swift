import Foundation
import XCTest
@testable import ImpulseTransport


private let startSeconds: Int64 = 1_000_000


final class ImpulseTokensTests: XCTestCase {
    func testRefreshPointIsDrawnInsideTheWindow() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        guard let point: Date = await tokens.refreshPointDate() else {
            XCTFail("a readable access token has a refresh point")
            return
        }

        XCTAssertEqual(point.timeIntervalSince1970, TimeInterval(startSeconds + 790), accuracy: 0.001)
    }


    func testRefreshPointStartsAtWindowOpeningWhenRandomIsZero() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.0)

        guard let point: Date = await tokens.refreshPointDate() else {
            XCTFail("a readable access token has a refresh point")
            return
        }

        XCTAssertEqual(point.timeIntervalSince1970, TimeInterval(startSeconds + 700), accuracy: 0.001)
    }


    func testTokenWithLessThanWindowLeftHasRefreshPointNow() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 100)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let point: Date? = await tokens.refreshPointDate()

        XCTAssertEqual(point, startDate())
    }


    func testOpaqueAccessTokenHasNoRefreshPoint() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = InMemorySessionStorage(
            tokens: ImpulseSessionTokens(accessToken: "opaque-token", refreshToken: "R1", userId: 7)
        )
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let point: Date? = await tokens.refreshPointDate()
        let needsRefresh: Bool = await tokens.needsProactiveRefresh()
        let unusable: Bool = await tokens.accessUnusable()

        XCTAssertNil(point)
        XCTAssertFalse(needsRefresh)
        XCTAssertFalse(unusable)
    }


    func testProactiveRefreshIsDueOnceThePointHasPassed() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let beforePoint: Bool = await tokens.needsProactiveRefresh()
        clock.advance(bySeconds: 800)
        let afterPoint: Bool = await tokens.needsProactiveRefresh()
        let unusable: Bool = await tokens.accessUnusable()

        XCTAssertFalse(beforePoint)
        XCTAssertTrue(afterPoint)
        XCTAssertFalse(unusable)
    }


    func testSuccessfulRefreshStoresTheNewPair() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let freshAccess: String = makeJwt(expirySeconds: startSeconds + 5000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [
                .authorization(
                    ImpulseRefreshAuthorization(
                        userId: 7,
                        sessionToken: freshAccess,
                        refreshToken: "R2",
                        grace: 30
                    )
                ),
            ]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let outcome: ImpulseRefreshOutcome = try await tokens.refresh()
        let bearer: String? = await tokens.bearer()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(bearer, freshAccess)
        XCTAssertEqual(storage.load(), ImpulseSessionTokens(accessToken: freshAccess, refreshToken: "R2", userId: 7))
    }


    func testIncompleteReplyIsRejectedAndKeepsTheSession() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let original: ImpulseSessionTokens = ImpulseSessionTokens(
            accessToken: makeJwt(expirySeconds: startSeconds + 1000),
            refreshToken: "R1",
            userId: 7
        )
        let storage: InMemorySessionStorage = InMemorySessionStorage(tokens: original)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [
                .authorization(
                    ImpulseRefreshAuthorization(
                        userId: 7,
                        sessionToken: makeJwt(expirySeconds: startSeconds + 5000),
                        refreshToken: "",
                        grace: 30
                    )
                ),
            ]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        await assertThrowsTokenError(ImpulseTokenError.incompleteReply) {
            _ = try await tokens.refresh()
        }

        XCTAssertEqual(storage.load(), original)
    }


    func testRefreshWithoutSessionReportsNoSession() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = InMemorySessionStorage(tokens: nil)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [])
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let outcome: ImpulseRefreshOutcome = try await tokens.refresh()
        let calls: [RecordedRefreshCall] = await transport.recordedCalls()

        XCTAssertEqual(outcome, .noSession)
        XCTAssertTrue(calls.isEmpty)
    }


    func testUnrecoverableErrorsClearTheSession() async throws {
        let unrecoverableTexts: [String] = ["AUTH_TOKEN_INVALID", "AUTH_TOKEN_EXPIRED", "SESSION_EXPIRED"]
        for text: String in unrecoverableTexts {
            let clock: ManualClock = ManualClock(start: startDate())
            let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
            let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(replies: [failure(text: text, code: 401)])
            let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

            let outcome: ImpulseRefreshOutcome = try await tokens.refresh()
            let hasSession: Bool = await tokens.hasSession()

            XCTAssertEqual(outcome, .sessionEnded, text)
            XCTAssertNil(storage.load(), text)
            XCTAssertFalse(hasSession, text)
        }
    }


    func testRefusedSocketTokenIsRetriedOnThePool() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [
                .failure(ImpulseCarrierFailure(sdkCode: 103, appCode: 0, appType: "", metadata: [:])),
                authorization(expirySeconds: startSeconds + 5000, refreshToken: "R2"),
            ]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let outcome: ImpulseRefreshOutcome = try await tokens.refresh()
        let calls: [RecordedRefreshCall] = await transport.recordedCalls()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(carriersOf(calls), [.updateSocket, .poolFleet])
    }


    func testExpiredAccessTokenRefreshesOverThePool() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds - 10)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [authorization(expirySeconds: startSeconds + 5000, refreshToken: "R2")]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let token: String? = try await tokens.connectionToken()
        let calls: [RecordedRefreshCall] = await transport.recordedCalls()

        XCTAssertEqual(token, makeJwt(expirySeconds: startSeconds + 5000))
        XCTAssertEqual(carriersOf(calls), [.poolFleet])
    }


    func testFloodWaitDefersTheRefreshBeforeTheWindowCloses() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [
                failure(text: "FLOOD_WAIT_60", code: 420),
                authorization(expirySeconds: startSeconds + 5000, refreshToken: "R2"),
            ]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let outcome: ImpulseRefreshOutcome = try await tokens.refresh()
        XCTAssertEqual(outcome, .deferred(retryAt: startDate().addingTimeInterval(60)))

        let whilePending: ImpulseRefreshOutcome = try await tokens.refresh()
        let callsWhilePending: [RecordedRefreshCall] = await transport.recordedCalls()
        XCTAssertEqual(whilePending, .deferred(retryAt: startDate().addingTimeInterval(60)))
        XCTAssertEqual(callsWhilePending.count, 1)

        clock.advance(bySeconds: 60)
        let afterWait: ImpulseRefreshOutcome = try await tokens.refresh()
        let callsAfterWait: [RecordedRefreshCall] = await transport.recordedCalls()
        XCTAssertEqual(afterWait, .refreshed)
        XCTAssertEqual(callsAfterWait.count, 2)
    }


    func testFloodWaitThatLandsInsideTheClosingWindowIsRejected() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 200)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [failure(text: "FLOOD_WAIT_100", code: 420)]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        await assertThrowsTokenError(
            ImpulseTokenError.refreshRejected(ImpulseRpcError(code: 420, text: "FLOOD_WAIT_100", temporary: false))
        ) {
            _ = try await tokens.refresh()
        }

        let hasSession: Bool = await tokens.hasSession()
        XCTAssertTrue(hasSession)
    }


    func testReplayedRefreshTokenWithinGraceKeepsTheSession() async throws {
        let clock: ManualClock = ManualClock(start: startDate())
        let storage: InMemorySessionStorage = sessionStorage(expirySeconds: startSeconds + 1000)
        let transport: ScriptedRefreshTransport = ScriptedRefreshTransport(
            replies: [
                authorization(expirySeconds: startSeconds + 5000, refreshToken: "R2"),
                failure(text: "AUTH_TOKEN_INVALID", code: 401),
                failure(text: "AUTH_TOKEN_INVALID", code: 401),
            ]
        )
        let tokens: ImpulseTokens = makeTokens(storage: storage, transport: transport, clock: clock, randomUnit: 0.5)

        let first: ImpulseRefreshOutcome = try await tokens.refresh()
        XCTAssertEqual(first, .refreshed)

        await tokens.onLoginTokens(
            ImpulseSessionTokens(
                accessToken: makeJwt(expirySeconds: startSeconds + 5000),
                refreshToken: "R1",
                userId: 7
            )
        )

        clock.advance(bySeconds: 10)
        await assertThrowsTokenError(
            ImpulseTokenError.refreshRejected(ImpulseRpcError(code: 401, text: "AUTH_TOKEN_INVALID", temporary: false))
        ) {
            _ = try await tokens.refresh()
        }
        let stillHasSession: Bool = await tokens.hasSession()
        XCTAssertTrue(stillHasSession)
        XCTAssertNotNil(storage.load())

        clock.advance(bySeconds: 31)
        let afterGrace: ImpulseRefreshOutcome = try await tokens.refresh()
        let hasSessionAfterGrace: Bool = await tokens.hasSession()
        XCTAssertEqual(afterGrace, .sessionEnded)
        XCTAssertFalse(hasSessionAfterGrace)
        XCTAssertNil(storage.load())
    }
}


private struct RecordedRefreshCall: Equatable {
    let refreshToken: String
    let carrier: ImpulseRefreshCarrier
}


private actor ScriptedRefreshTransport: ImpulseRefreshTransport {
    private var replies: [ImpulseRefreshReply]
    private var calls: [RecordedRefreshCall] = []


    init(replies: [ImpulseRefreshReply]) {
        self.replies = replies
    }


    func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply {
        calls.append(RecordedRefreshCall(refreshToken: refreshToken, carrier: carrier))
        if replies.isEmpty {
            return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "NO_SCRIPTED_REPLY", metadata: [:]))
        }

        return replies.removeFirst()
    }


    func recordedCalls() -> [RecordedRefreshCall] {
        return calls
    }
}


private final class InMemorySessionStorage: ImpulseSessionStorage, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: ImpulseSessionTokens?


    init(tokens: ImpulseSessionTokens?) {
        self.stored = tokens
    }


    func load() -> ImpulseSessionTokens? {
        lock.lock()
        defer {
            lock.unlock()
        }

        return stored
    }


    func save(_ tokens: ImpulseSessionTokens) {
        lock.lock()
        defer {
            lock.unlock()
        }

        stored = tokens
    }


    func clear() {
        lock.lock()
        defer {
            lock.unlock()
        }

        stored = nil
    }
}


private final class ManualClock: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var current: Date


    init(start: Date) {
        self.current = start
    }


    func now() -> Date {
        lock.lock()
        defer {
            lock.unlock()
        }

        return current
    }


    func advance(bySeconds seconds: TimeInterval) {
        lock.lock()
        defer {
            lock.unlock()
        }

        current = current.addingTimeInterval(seconds)
    }
}


private func startDate() -> Date {
    return Date(timeIntervalSince1970: TimeInterval(1_000_000))
}


private func carriersOf(_ calls: [RecordedRefreshCall]) -> [ImpulseRefreshCarrier] {
    var carriers: [ImpulseRefreshCarrier] = []
    for call: RecordedRefreshCall in calls {
        carriers.append(call.carrier)
    }

    return carriers
}


private func sessionStorage(expirySeconds: Int64) -> InMemorySessionStorage {
    return InMemorySessionStorage(
        tokens: ImpulseSessionTokens(
            accessToken: makeJwt(expirySeconds: expirySeconds),
            refreshToken: "R1",
            userId: 7
        )
    )
}


private func makeTokens(
    storage: InMemorySessionStorage,
    transport: ScriptedRefreshTransport,
    clock: ManualClock,
    randomUnit: Double
) -> ImpulseTokens {
    return ImpulseTokens(
        storage: storage,
        transport: transport,
        clock: { clock.now() },
        randomUnit: { randomUnit }
    )
}


private func authorization(
    expirySeconds: Int64,
    refreshToken: String
) -> ImpulseRefreshReply {
    return .authorization(
        ImpulseRefreshAuthorization(
            userId: 7,
            sessionToken: makeJwt(expirySeconds: expirySeconds),
            refreshToken: refreshToken,
            grace: 30
        )
    )
}


private func failure(
    text: String,
    code: Int
) -> ImpulseRefreshReply {
    return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: code, appType: text, metadata: [:]))
}


private func makeJwt(expirySeconds: Int64) -> String {
    let payloadJson: String = "{\"exp\":\(expirySeconds),\"sub\":\"i:0123456789abcdef0123456789abcdef\"}"
    let payload: String = base64Url(Data(payloadJson.utf8))
    return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2ln"
}


private func base64Url(_ data: Data) -> String {
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}


private func assertThrowsTokenError(
    _ expected: ImpulseTokenError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected) to be thrown")
    } catch let error as ImpulseTokenError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("unexpected error \(error)")
    }
}
