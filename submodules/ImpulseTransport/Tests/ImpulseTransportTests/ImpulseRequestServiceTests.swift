import Foundation
import XCTest
@testable import ImpulseTransport


private final class RequestServiceSession: ImpulseRequestSession, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var loggedIn: Bool
    private var proactive: Bool
    private var refreshes: Int = 0
    private let refreshOutcome: ImpulseRefreshOutcome


    init(
        loggedIn: Bool,
        proactive: Bool,
        refreshOutcome: ImpulseRefreshOutcome
    ) {
        self.loggedIn = loggedIn
        self.proactive = proactive
        self.refreshOutcome = refreshOutcome
    }


    func setLoggedIn(_ value: Bool) {
        self.lock.lock()
        self.loggedIn = value
        self.lock.unlock()
    }


    func refreshCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.refreshes
    }


    func hasSession() async -> Bool {
        return self.currentLoggedIn()
    }


    func needsProactiveRefresh() async -> Bool {
        return self.currentProactive()
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        self.recordRefresh()
        return self.refreshOutcome
    }


    private func currentLoggedIn() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.loggedIn
    }


    private func currentProactive() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.proactive
    }


    private func recordRefresh() {
        self.lock.lock()
        self.refreshes += 1
        self.lock.unlock()
    }
}


private final class RequestServiceCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private let delays: [String: TimeInterval]
    private var started: [String] = []
    private var completed: [String] = []


    init(
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        delays: [String: TimeInterval]
    ) {
        self.replies = replies
        self.delays = delays
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let reply: Result<[UInt8], ImpulseCarrierFailure> = self.startCall(method: method)
        let delay: TimeInterval = self.delays[method] ?? 0
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        self.recordCompletion(method: method)
        return reply
    }


    func sentMethods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.started
    }


    func completedMethods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.completed
    }


    private func startCall(method: String) -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.started.append(method)
        if self.replies.isEmpty {
            return .success([])
        }
        return self.replies.removeFirst()
    }


    private func recordCompletion(method: String) {
        self.lock.lock()
        self.completed.append(method)
        self.lock.unlock()
    }
}


private final class RequestServiceGate: ImpulseDeclarationGate, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var invalidations: Int = 0


    func awaitDeclared(timeoutSeconds: TimeInterval) async -> Bool {
        return true
    }


    func invalidate() async {
        self.lock.lock()
        self.invalidations += 1
        self.lock.unlock()
    }


    func invalidationCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.invalidations
    }
}


private final class RequestServiceCounter: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var count: Int = 0


    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }


    func value() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.count
    }
}


private func request(method: String) -> ImpulseEncodedRequest {
    return ImpulseEncodedRequest(
        methodId: 1,
        method: method,
        path: "/" + method,
        proto: [1, 2, 3],
        takeoutId: nil
    )
}


private func apiFailure(
    code: Int,
    text: String
) -> Result<[UInt8], ImpulseCarrierFailure> {
    return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: code, appType: text, metadata: [:]))
}


private func makeService(
    session: RequestServiceSession,
    update: RequestServiceCarrier,
    gate: RequestServiceGate?,
    signedIn: Bool,
    counter: RequestServiceCounter
) -> ImpulseRequestService {
    let unused: RequestServiceCarrier = RequestServiceCarrier(replies: [], delays: [:])
    return ImpulseRequestService(
        session: session,
        updateCarrier: update,
        mediaCarrier: unused,
        poolCarrier: unused,
        declarations: gate,
        signedIn: signedIn,
        onAuthorizationRequired: {
            counter.increment()
        }
    )
}


final class ImpulseRequestServiceTests: XCTestCase {
    func testDeadlinesAreTheCanonicalValues() {
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .update), 30)
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .pool), 30)
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .media), 10)
        XCTAssertEqual(ImpulseRequestTimeouts.declarationWaitSeconds, 10)
        XCTAssertEqual(ImpulseRequestTimeouts.blockingWaitSeconds(callSeconds: 30), 35)
    }


    func testFloodWaitIsRetriedAfterItsSeconds() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 420, text: "FLOOD_WAIT_5", temporary: false)

        let decision: ImpulseRequestDecision = ImpulseRequestPolicy.decide(
            error: error,
            options: ImpulseRequestOptions(),
            failureCount: 1
        )

        XCTAssertEqual(decision, .retryAfter(seconds: 5))
    }


    func testFloodWaitWithoutNumberWaitsTwoSeconds() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 420, text: "FLOOD_WAIT", temporary: false)

        let decision: ImpulseRequestDecision = ImpulseRequestPolicy.decide(
            error: error,
            options: ImpulseRequestOptions(),
            failureCount: 1
        )

        XCTAssertEqual(decision, .retryAfter(seconds: 2))
    }


    func testSlowmodeWaitIsDelivered() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 420, text: "SLOWMODE_WAIT_30", temporary: false)

        let decision: ImpulseRequestDecision = ImpulseRequestPolicy.decide(
            error: error,
            options: ImpulseRequestOptions(),
            failureCount: 1
        )

        XCTAssertEqual(decision, .deliver)
    }


    func testFloodWaitIsDeliveredWhenServerErrorsFailUnlessExcepted() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 420, text: "FLOOD_WAIT_3", temporary: false)
        let failing: ImpulseRequestOptions = ImpulseRequestOptions(failOnServerErrors: true)
        let excepted: ImpulseRequestOptions = ImpulseRequestOptions(
            failOnServerErrors: true,
            failOnServerErrorsExceptFloodWait: true
        )

        XCTAssertEqual(ImpulseRequestPolicy.decide(error: error, options: failing, failureCount: 1), .deliver)
        XCTAssertEqual(ImpulseRequestPolicy.decide(error: error, options: excepted, failureCount: 1), .retryAfter(seconds: 3))
    }


    func testDoNotWaitFloodWaitDeliversAtOnce() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 420, text: "FLOOD_WAIT_3", temporary: false)
        let options: ImpulseRequestOptions = ImpulseRequestOptions(doNotWaitFloodWait: true)

        XCTAssertEqual(ImpulseRequestPolicy.decide(error: error, options: options, failureCount: 1), .deliver)
    }


    func testServiceUnavailableAndNegativeCodesAreRetriedWithBackoff() {
        let unavailable: ImpulseRpcError = ImpulseRpcError(code: 503, text: "SERVICE_UNAVAILABLE", temporary: false)
        let negative: ImpulseRpcError = ImpulseRpcError(code: -500, text: "NEGATIVE", temporary: false)

        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: unavailable, options: ImpulseRequestOptions(), failureCount: 3),
            .retryAfter(seconds: 3)
        )
        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: negative, options: ImpulseRequestOptions(), failureCount: 20),
            .retryAfter(seconds: 10)
        )
    }


    func testServerErrorsAreDeliveredWhenTheRequestFailsOnThem() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 500, text: "INTERNAL", temporary: false)
        let options: ImpulseRequestOptions = ImpulseRequestOptions(failOnServerErrors: true)

        XCTAssertEqual(ImpulseRequestPolicy.decide(error: error, options: options, failureCount: 1), .deliver)
    }


    func testMessageWaitFailedRetriesAtOnce() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 400, text: "MSG_WAIT_FAILED", temporary: false)

        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: error, options: ImpulseRequestOptions(), failureCount: 1),
            .retryAfter(seconds: 0)
        )
    }


    func testUnauthorizedRequiresAuthorizationExceptPasswordNeeded() {
        let revoked: ImpulseRpcError = ImpulseRpcError(code: 401, text: "SESSION_REVOKED", temporary: false)
        let password: ImpulseRpcError = ImpulseRpcError(code: 401, text: "SESSION_PASSWORD_NEEDED", temporary: false)

        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: revoked, options: ImpulseRequestOptions(), failureCount: 1),
            .authorizationRequired
        )
        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: password, options: ImpulseRequestOptions(), failureCount: 1),
            .deliver
        )
    }


    func testMustWaitForLoginOnlyWithoutLoginAndWithoutTheFlag() {
        XCTAssertTrue(ImpulseRequestPolicy.mustWaitForLogin(options: ImpulseRequestOptions(), loggedIn: false))
        XCTAssertFalse(ImpulseRequestPolicy.mustWaitForLogin(options: ImpulseRequestOptions(withoutLogin: true), loggedIn: false))
        XCTAssertFalse(ImpulseRequestPolicy.mustWaitForLogin(options: ImpulseRequestOptions(), loggedIn: true))
    }


    func testRefusedMethodIsAnsweredWithoutSending() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [], delays: [:])
        let counter: RequestServiceCounter = RequestServiceCounter()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: counter
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "auth.sendCode"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(
            result.failureValue,
            .rpc(ImpulseRpcError(code: 400, text: "CLIENT_IDENTITY_REFUSED", temporary: false))
        )
        XCTAssertTrue(carrier.sentMethods().isEmpty)
    }


    func testServerErrorIsRetriedUntilAReplyArrives() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 503, text: "SERVICE_UNAVAILABLE"), .success([7])],
            delays: [:]
        )
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [7])
        XCTAssertEqual(carrier.sentMethods().count, 2)
    }


    func testFailOnServerErrorsDeliversTheError() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 500, text: "INTERNAL")],
            delays: [:]
        )
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions(failOnServerErrors: true)
        )

        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: 500, text: "INTERNAL", temporary: false)))
        XCTAssertEqual(carrier.sentMethods().count, 1)
    }


    func testConnectionNotInitedRedeclaresOncePerExecute() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [
                apiFailure(code: 400, text: "CONNECTION_NOT_INITED"),
                apiFailure(code: 400, text: "CONNECTION_NOT_INITED"),
                apiFailure(code: 400, text: "CONNECTION_NOT_INITED"),
            ],
            delays: [:]
        )
        let gate: RequestServiceGate = RequestServiceGate()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: gate,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(gate.invalidationCount(), 1)
        XCTAssertEqual(carrier.sentMethods().count, 2)
        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: 400, text: "CONNECTION_NOT_INITED", temporary: false)))
    }


    func testRefusedTokenRefreshesAndRetriesOnce() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 401, text: "AUTH_KEY_UNREGISTERED"), .success([5])],
            delays: [:]
        )
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [5])
        XCTAssertEqual(session.refreshCount(), 1)
    }


    func testRevokedSessionReportsAuthorizationRequired() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 401, text: "SESSION_REVOKED")],
            delays: [:]
        )
        let counter: RequestServiceCounter = RequestServiceCounter()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: counter
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "account.getPassword"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(counter.value(), 1)
        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: 401, text: "SESSION_REVOKED", temporary: false)))
    }


    func testPasswordNeededDoesNotReportAuthorizationRequired() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 401, text: "SESSION_PASSWORD_NEEDED")],
            delays: [:]
        )
        let counter: RequestServiceCounter = RequestServiceCounter()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: counter
        )

        _ = await service.execute(
            request: request(method: "account.getPassword"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(counter.value(), 0)
    }


    func testRequestWithoutLoginIsSentAtOnce() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: false, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [.success([4])], delays: [:])
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: false,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "help.getConfig"),
            options: ImpulseRequestOptions(withoutLogin: true)
        )

        XCTAssertEqual(result.successValue, [4])
    }


    func testRequestNeedingLoginIsHeldUntilSignedIn() async throws {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: false, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [.success([9])], delays: [:])
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: false,
            counter: RequestServiceCounter()
        )

        let call: ImpulseRequestCall = service.submit(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(carrier.sentMethods().isEmpty)

        session.setLoggedIn(true)
        service.setSignedIn(true)
        let result: Result<[UInt8], ImpulseRequestFailure> = await call.result.value

        XCTAssertEqual(result.successValue, [9])
        XCTAssertEqual(carrier.sentMethods().count, 1)
    }


    func testDependentRequestRunsAfterItsPredecessorSettles() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [],
            delays: ["messages.first": 0.2]
        )
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let first: ImpulseRequestCall = service.submit(
            request: request(method: "messages.first"),
            options: ImpulseRequestOptions()
        )
        let second: ImpulseRequestCall = service.submit(
            request: request(method: "messages.second"),
            options: ImpulseRequestOptions(),
            dependsOn: first
        )
        _ = await first.result.value
        _ = await second.result.value

        XCTAssertEqual(carrier.completedMethods(), ["messages.first", "messages.second"])
    }
}


private extension Result {
    var successValue: Success? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }


    var failureValue: Failure? {
        if case .failure(let value) = self {
            return value
        }
        return nil
    }
}
