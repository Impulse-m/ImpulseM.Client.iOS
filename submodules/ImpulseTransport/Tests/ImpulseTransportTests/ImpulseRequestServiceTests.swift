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


private final class RequestServiceFlakySession: ImpulseRequestSession, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let proactive: Bool
    private var failingRefreshes: Int
    private var refreshes: Int = 0


    init(
        proactive: Bool,
        failingRefreshes: Int
    ) {
        self.proactive = proactive
        self.failingRefreshes = failingRefreshes
    }


    func refreshCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.refreshes
    }


    func hasSession() async -> Bool {
        return true
    }


    func needsProactiveRefresh() async -> Bool {
        return self.proactive
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        if self.recordRefresh() {
            throw ImpulseTokenError.carrierFailure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
        }
        return .refreshed
    }


    private func recordRefresh() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.refreshes += 1
        if self.failingRefreshes > 0 {
            self.failingRefreshes -= 1
            return true
        }
        return false
    }
}


/// A clock that moves only when the service waits, so no retry or deadline waits in real time.
private final class RequestServiceClock: ImpulseRequestClock, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var now: TimeInterval = 0
    private var waits: [TimeInterval] = []


    func nowSeconds() -> TimeInterval {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.now
    }


    func sleep(seconds: TimeInterval) async throws {
        self.lock.lock()
        self.now += seconds
        self.waits.append(seconds)
        self.lock.unlock()
        try Task.checkCancellation()
    }


    func waitedSeconds() -> [TimeInterval] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.waits
    }
}


private final class RequestServiceCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private let delays: [String: TimeInterval]
    private var started: [String] = []
    private var completed: [String] = []
    private var timeouts: [TimeInterval] = []


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
        self.recordTimeout(timeoutSeconds)
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


    func sentTimeouts() -> [TimeInterval] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.timeouts
    }


    private func recordTimeout(_ timeoutSeconds: TimeInterval) {
        self.lock.lock()
        self.timeouts.append(timeoutSeconds)
        self.lock.unlock()
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


/// A carrier that advances the route epoch of its service during the send numbered in `advanceOnSends` (sends count
/// from 1), before it returns the reply. That is a route change that lands while the call is in flight.
private final class RouteEpochCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private let advanceOnSends: Set<Int>
    private var sends: Int = 0
    private weak var service: ImpulseRequestService? = nil


    init(
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        advanceOnSends: Set<Int>
    ) {
        self.replies = replies
        self.advanceOnSends = advanceOnSends
    }


    func attach(_ service: ImpulseRequestService) {
        self.lock.lock()
        self.service = service
        self.lock.unlock()
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        self.sends += 1
        let sendNumber: Int = self.sends
        let reply: Result<[UInt8], ImpulseCarrierFailure> = self.replies.isEmpty ? .success([]) : self.replies.removeFirst()
        let attached: ImpulseRequestService? = self.service
        self.lock.unlock()

        if self.advanceOnSends.contains(sendNumber) {
            attached?.advanceRouteEpoch()
        }
        return reply
    }


    func sendCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sends
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


private func networkFailure() -> Result<[UInt8], ImpulseCarrierFailure> {
    return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
}


private func makeService(
    session: RequestServiceSession,
    update: RequestServiceCarrier,
    gate: RequestServiceGate?,
    signedIn: Bool,
    counter: RequestServiceCounter,
    clock: RequestServiceClock = RequestServiceClock(),
    loginGate: ImpulseLoginGate? = nil
) -> ImpulseRequestService {
    let unused: RequestServiceCarrier = RequestServiceCarrier(replies: [], delays: [:])
    return ImpulseRequestService(
        session: session,
        updateCarrier: update,
        mediaCarrier: update,
        poolCarrier: unused,
        declarations: gate,
        signedIn: signedIn,
        onAuthorizationRequired: {
            counter.increment()
        },
        clock: clock,
        loginGate: loginGate
    )
}


private func makeEpochService(
    carrier: RouteEpochCarrier,
    clock: RequestServiceClock
) -> ImpulseRequestService {
    let unused: RequestServiceCarrier = RequestServiceCarrier(replies: [], delays: [:])
    let service: ImpulseRequestService = ImpulseRequestService(
        session: RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed),
        updateCarrier: carrier,
        mediaCarrier: carrier,
        poolCarrier: unused,
        declarations: nil,
        signedIn: true,
        onAuthorizationRequired: {
        },
        clock: clock
    )
    carrier.attach(service)
    return service
}


final class ImpulseRequestServiceTests: XCTestCase {
    func testDeadlinesAreTheCanonicalValues() {
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .update), 30)
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .pool), 30)
        XCTAssertEqual(ImpulseRequestTimeouts.callSeconds(route: .media), 10)
        XCTAssertEqual(ImpulseRequestTimeouts.declarationWaitSeconds, 10)
        XCTAssertEqual(ImpulseRequestTimeouts.blockingWaitSeconds(callSeconds: 30), 35)
    }


    func testRequestsHaveNoTotalDeadlineByDefault() {
        XCTAssertNil(ImpulseRequestOptions().totalDeadlineSeconds)
        XCTAssertEqual(ImpulseRequestOptions(totalDeadlineSeconds: 10).totalDeadlineSeconds, 10)
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


    func testWorkerBusyOnServerErrorRetriesAtOnce() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 500, text: "WORKER_BUSY_TOO_LONG_RETRY", temporary: false)

        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: error, options: ImpulseRequestOptions(), failureCount: 3),
            .retryAfter(seconds: 0)
        )
    }


    func testWorkerBusyOnServiceUnavailableIsBackedOff() {
        let error: ImpulseRpcError = ImpulseRpcError(code: 503, text: "WORKER_BUSY_TOO_LONG_RETRY", temporary: false)

        XCTAssertEqual(
            ImpulseRequestPolicy.decide(error: error, options: ImpulseRequestOptions(), failureCount: 3),
            .retryAfter(seconds: 3)
        )
    }


    func testNetworkFailureWaitGrowsPerAttemptAndIsCapped() {
        XCTAssertEqual(ImpulseRequestPolicy.networkFailureSeconds(attempt: 1), 1)
        XCTAssertEqual(ImpulseRequestPolicy.networkFailureSeconds(attempt: 0), 1)
        XCTAssertEqual(ImpulseRequestPolicy.networkFailureSeconds(attempt: 4), 4)
        XCTAssertEqual(ImpulseRequestPolicy.networkFailureSeconds(attempt: 50), 10)
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


    /// The installer stores the tokens before it rekeys the socket and opens the gate. A call that starts in between sees a
    /// stored session, but it waits for the gate, and it is sent only after the gate opens.
    func testRequestNeedingLoginWaitsWhileTheGateIsClosedEvenWithStoredTokens() async throws {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [.success([9])], delays: [:])
        let gate: ImpulseLoginGate = ImpulseLoginGate(isOpen: false)
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: false,
            counter: RequestServiceCounter(),
            loginGate: gate
        )

        let call: ImpulseRequestCall = service.submit(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(carrier.sentMethods().isEmpty)

        gate.setOpen(true)
        let result: Result<[UInt8], ImpulseRequestFailure> = await call.result.value

        XCTAssertEqual(result.successValue, [9])
        XCTAssertEqual(carrier.sentMethods(), ["messages.sendMessage"])
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


    func testNetworkFailureIsRetriedUntilAReplyArrives() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [networkFailure(), .success([6])],
            delays: [:]
        )
        let counter: RequestServiceCounter = RequestServiceCounter()
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: counter,
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [6])
        XCTAssertEqual(carrier.sentMethods().count, 2)
        XCTAssertEqual(clock.waitedSeconds(), [1])
        XCTAssertEqual(counter.value(), 0)
    }


    /// Without a total deadline a network failure keeps being retried, waiting one second longer each time, until a
    /// reply arrives. The carrier script ends in a reply, so the call ends.
    func testNetworkFailureWithoutDeadlineKeepsRetrying() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [networkFailure(), networkFailure(), networkFailure(), .success([6])],
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [6])
        XCTAssertEqual(carrier.sentMethods().count, 4)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 3])
    }


    /// With a total deadline the call ends with the network failure once the deadline passes. The waits 1, 2, 3 and 4
    /// end at the 10-second deadline, so the fifth reply is never requested.
    func testNetworkFailureEndsWithNetworkFailureAtDeadline() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [networkFailure(), networkFailure(), networkFailure(), networkFailure(), .success([6])],
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions(totalDeadlineSeconds: 10)
        )

        XCTAssertEqual(result.failureValue, .network(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])))
        XCTAssertEqual(carrier.sentMethods().count, 4)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 3, 4])
        XCTAssertEqual(clock.nowSeconds(), 10)
    }


    /// Each send is cut to the time left before the total deadline, and each wait is cut at the deadline too. The
    /// sends time out at 5, 4 and 2 seconds, and the waits are 1, 2 and 2 seconds.
    func testSendsAndWaitsAreCutToTheDeadline() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [networkFailure(), networkFailure(), networkFailure(), .success([6])],
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions(totalDeadlineSeconds: 5)
        )

        XCTAssertEqual(result.failureValue, .network(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])))
        XCTAssertEqual(carrier.sentTimeouts(), [5, 4, 2])
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 2])
    }


    /// A deadline that has already passed sends nothing and ends with the network failure.
    func testPassedDeadlineSendsNothing() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [.success([6])], delays: [:])
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions(totalDeadlineSeconds: 0)
        )

        XCTAssertEqual(result.failureValue, .network(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])))
        XCTAssertTrue(carrier.sentMethods().isEmpty)
    }


    /// A flood wait is cut at the deadline as well, and the call then ends with the RPC error it was waiting out.
    func testFloodWaitIsCutAtTheDeadlineAndEndsWithItsError() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 420, text: "FLOOD_WAIT_20"), .success([6])],
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions(totalDeadlineSeconds: 5)
        )

        guard case .some(.rpc(let error)) = result.failureValue else {
            XCTFail("a flood wait cut at the deadline must end with its RPC error")
            return
        }
        XCTAssertEqual(error.text, "FLOOD_WAIT_20")
        XCTAssertEqual(carrier.sentMethods().count, 1)
        XCTAssertEqual(clock.waitedSeconds(), [5])
    }


    func testThrownProactiveRefreshIsRetriedWithoutSessionExpired() async {
        let session: RequestServiceFlakySession = RequestServiceFlakySession(proactive: true, failingRefreshes: 1)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [.success([8])], delays: [:])
        let counter: RequestServiceCounter = RequestServiceCounter()
        let service: ImpulseRequestService = ImpulseRequestService(
            session: session,
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: true,
            onAuthorizationRequired: {
                counter.increment()
            },
            clock: RequestServiceClock()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [8])
        XCTAssertEqual(session.refreshCount(), 2)
        XCTAssertEqual(counter.value(), 0)
    }


    func testThrownReactiveRefreshIsRetriedWithoutAuthorizationRequired() async {
        let session: RequestServiceFlakySession = RequestServiceFlakySession(proactive: false, failingRefreshes: 1)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: [apiFailure(code: 401, text: "AUTH_KEY_UNREGISTERED"), .success([5])],
            delays: [:]
        )
        let counter: RequestServiceCounter = RequestServiceCounter()
        let service: ImpulseRequestService = ImpulseRequestService(
            session: session,
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: true,
            onAuthorizationRequired: {
                counter.increment()
            },
            clock: RequestServiceClock()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [5])
        XCTAssertEqual(session.refreshCount(), 1)
        XCTAssertEqual(carrier.sentMethods().count, 2)
        XCTAssertEqual(counter.value(), 0)
    }


    /// The sixth network failure of a download ends the call with `-123 RETRY_LIMIT`. The script fails more often than
    /// that, so only the limit ends the call: six sends and five waits of 1 to 5 seconds, none after the sixth failure.
    func testDownloadGivesRetryLimitAfterSixNetworkFailures() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: Array(repeating: networkFailure(), count: 10),
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "upload.getFile"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: -123, text: "RETRY_LIMIT", temporary: false)))
        XCTAssertEqual(carrier.sentMethods().count, 6)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 3, 4, 5])
    }


    /// A download that gets its reply on the sixth attempt is not cut short: five failures, then the reply.
    func testDownloadReplyOnSixthAttemptIsDelivered() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        var replies: [Result<[UInt8], ImpulseCarrierFailure>] = Array(repeating: networkFailure(), count: 5)
        replies.append(.success([9]))
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: replies, delays: [:])
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: RequestServiceClock()
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "upload.getWebFile"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [9])
        XCTAssertEqual(carrier.sentMethods().count, 6)
    }


    /// With `forceDownload` the limit is 10 network failures: ten sends and nine waits of 1 to 9 seconds.
    func testForceDownloadGivesRetryLimitAfterTenNetworkFailures() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(
            replies: Array(repeating: networkFailure(), count: 12),
            delays: [:]
        )
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "upload.getFile"),
            options: ImpulseRequestOptions(forceDownload: true)
        )

        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: -123, text: "RETRY_LIMIT", temporary: false)))
        XCTAssertEqual(carrier.sentMethods().count, 10)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }


    /// A request that is not a download keeps retrying network failures past the download limit, until its reply.
    func testNonDownloadKeepsRetryingPastTheDownloadLimit() async {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: true, proactive: false, refreshOutcome: .refreshed)
        var replies: [Result<[UInt8], ImpulseCarrierFailure>] = Array(repeating: networkFailure(), count: 9)
        replies.append(.success([6]))
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: replies, delays: [:])
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: true,
            counter: RequestServiceCounter(),
            clock: clock
        )

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [6])
        XCTAssertEqual(carrier.sentMethods().count, 10)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }


    /// A failure of a send that ran under an older route epoch spends no budget. Eight such failures are more than a
    /// download allows, so only the reply ends the call. Each failure waits the policy delay for the first attempt, one
    /// second, so no retry runs at zero delay.
    func testEpochAdvanceFailuresAreRetriedWithoutSpendingTheBudget() async {
        let replies: [Result<[UInt8], ImpulseCarrierFailure>] = Array(repeating: networkFailure(), count: 8) + [.success([7])]
        let carrier: RouteEpochCarrier = RouteEpochCarrier(replies: replies, advanceOnSends: Set(1 ... 8))
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeEpochService(carrier: carrier, clock: clock)

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "upload.getFile"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.successValue, [7])
        XCTAssertEqual(carrier.sendCount(), 9)
        XCTAssertEqual(clock.waitedSeconds(), Array(repeating: 1, count: 8))
    }


    /// A retried call takes the current epoch when it runs again. The first send fails under an older epoch and spends
    /// nothing; the six failures after it are counted, so the download ends with RETRY_LIMIT on the seventh send, with
    /// the waits of six counted failures from the first attempt.
    func testRetriedCallTakesTheCurrentEpochWhenItRunsAgain() async {
        let replies: [Result<[UInt8], ImpulseCarrierFailure>] = Array(repeating: networkFailure(), count: 7)
        let carrier: RouteEpochCarrier = RouteEpochCarrier(replies: replies, advanceOnSends: [1])
        let clock: RequestServiceClock = RequestServiceClock()
        let service: ImpulseRequestService = makeEpochService(carrier: carrier, clock: clock)

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: request(method: "upload.getFile"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(result.failureValue, .rpc(ImpulseRpcError(code: -123, text: "RETRY_LIMIT", temporary: false)))
        XCTAssertEqual(carrier.sendCount(), 7)
        XCTAssertEqual(clock.waitedSeconds(), [1, 1, 2, 3, 4, 5])
    }


    /// A request cancelled while it waits for a login never sends, and it settles as canceled after a route epoch advance.
    func testCancelledRequestSettlesAsCanceledAfterAnEpochAdvance() async throws {
        let session: RequestServiceSession = RequestServiceSession(loggedIn: false, proactive: false, refreshOutcome: .refreshed)
        let carrier: RequestServiceCarrier = RequestServiceCarrier(replies: [networkFailure(), .success([7])], delays: [:])
        let service: ImpulseRequestService = makeService(
            session: session,
            update: carrier,
            gate: nil,
            signedIn: false,
            counter: RequestServiceCounter()
        )
        service.advanceRouteEpoch()

        let call: ImpulseRequestCall = service.submit(
            request: request(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        call.cancel()
        let result: Result<[UInt8], ImpulseRequestFailure> = await call.result.value

        XCTAssertEqual(result.failureValue, .canceled)
        XCTAssertTrue(carrier.sentMethods().isEmpty)
    }


    /// A failure of a call that sent under an older route epoch is `routeChanged`, whatever the error is: the lost
    /// connection, a closed fleet, a disconnected pool client, a media route change, and any other carrier failure.
    func testFailureUnderAnEpochAdvanceIsRouteChanged() {
        let network: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
        let server: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 500, appType: "INTERNAL", metadata: [:])

        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulseMediaFailure.routeChanged, epochAdvanced: true), .routeChanged)
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulseMediaFailure.closed, epochAdvanced: true), .routeChanged)
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulsePoolFailure.mainDisconnected, epochAdvanced: true), .routeChanged)
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: network, epochAdvanced: true), .routeChanged)
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: server, epochAdvanced: true), .routeChanged)
    }


    /// Without an epoch advance a failure keeps its carrier failure.
    func testFailureWithoutAnEpochAdvanceKeepsItsCarrierFailure() {
        let network: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
        let server: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 500, appType: "INTERNAL", metadata: [:])

        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulseMediaFailure.routeChanged, epochAdvanced: false), .network(network))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulseMediaFailure.closed, epochAdvanced: false), .network(network))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulsePoolFailure.mainDisconnected, epochAdvanced: false), .network(network))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: network, epochAdvanced: false), .network(network))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: server, epochAdvanced: false), .network(server))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulseMediaFailure.queueFull, epochAdvanced: false), .network(network))
        XCTAssertEqual(ImpulseRequestPolicy.failure(for: ImpulsePoolFailure.sessionEnded, epochAdvanced: false), .network(network))
    }


    func testDownloadRetryLimitIsSixOrTenWithForceDownload() {
        let limitError: ImpulseRpcError = ImpulseRpcError(code: -123, text: "RETRY_LIMIT", temporary: false)
        let forced: ImpulseRequestOptions = ImpulseRequestOptions(forceDownload: true)

        XCTAssertNil(ImpulseRequestPolicy.downloadRetryLimit(method: "upload.getFile", options: ImpulseRequestOptions(), attempt: 5))
        XCTAssertEqual(
            ImpulseRequestPolicy.downloadRetryLimit(method: "upload.getFile", options: ImpulseRequestOptions(), attempt: 6),
            limitError
        )
        XCTAssertEqual(
            ImpulseRequestPolicy.downloadRetryLimit(method: "upload.getWebFile", options: ImpulseRequestOptions(), attempt: 7),
            limitError
        )
        XCTAssertNil(ImpulseRequestPolicy.downloadRetryLimit(method: "upload.getFile", options: forced, attempt: 9))
        XCTAssertEqual(ImpulseRequestPolicy.downloadRetryLimit(method: "upload.getFile", options: forced, attempt: 10), limitError)
        XCTAssertNil(ImpulseRequestPolicy.downloadRetryLimit(method: "messages.sendMessage", options: forced, attempt: 50))
        XCTAssertNil(ImpulseRequestPolicy.downloadRetryLimit(method: "upload.saveFilePart", options: ImpulseRequestOptions(), attempt: 50))
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
