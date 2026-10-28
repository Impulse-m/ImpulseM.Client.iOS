import Foundation
import XCTest
@testable import ImpulseTransport


private struct NetworkSessionTokens: ImpulseRequestSession {
    func hasSession() async -> Bool {
        return true
    }


    func needsProactiveRefresh() async -> Bool {
        return false
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        return .refreshed
    }
}


/// The SDK code of a cancelled carrier call.
private let networkSessionCancelledCode: Int = 17


/// Answers the sends with the queued replies in order. Once the queue is empty every send is answered as cancelled, so
/// a call that keeps retrying still ends.
private final class NetworkSessionCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private var sends: Int = 0


    init(replies: [Result<[UInt8], ImpulseCarrierFailure>]) {
        self.replies = replies
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let index: Int = self.sends
        self.sends += 1
        if index < self.replies.count {
            return self.replies[index]
        }
        return .failure(ImpulseCarrierFailure(sdkCode: networkSessionCancelledCode, appCode: 0, appType: "", metadata: [:]))
    }


    func sendCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sends
    }
}


/// A clock that moves only when the session waits, so no retry waits in real time.
private final class NetworkSessionClock: ImpulseRequestClock, @unchecked Sendable {
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


private final class NetworkSessionCounter: @unchecked Sendable {
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


private final class NetworkSessionDelegateSpy: ImpulseNetworkSessionDelegate, @unchecked Sendable {
    private let counter: NetworkSessionCounter = NetworkSessionCounter()


    func networkSessionAuthorizationRequired() {
        self.counter.increment()
    }


    func authorizationCount() -> Int {
        return self.counter.value()
    }
}


final class ImpulseNetworkSessionTests: XCTestCase {
    private func makeSession(
        datacenterId: Int,
        role: ImpulseSessionRole,
        reply: Result<[UInt8], ImpulseCarrierFailure>,
        delegate: (any ImpulseNetworkSessionDelegate)?
    ) throws -> ImpulseNetworkSession {
        return try makeSession(
            datacenterId: datacenterId,
            role: role,
            replies: [reply],
            delegate: delegate,
            clock: NetworkSessionClock()
        )
    }


    private func makeSession(
        datacenterId: Int,
        role: ImpulseSessionRole,
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        delegate: (any ImpulseNetworkSessionDelegate)?,
        clock: NetworkSessionClock
    ) throws -> ImpulseNetworkSession {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let carrier: NetworkSessionCarrier = NetworkSessionCarrier(replies: replies)
        return ImpulseNetworkSession(
            datacenterId: datacenterId,
            role: role,
            transcoder: transcoder,
            session: NetworkSessionTokens(),
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: true,
            delegate: delegate,
            clock: clock
        )
    }


    /// The TL bytes of `auth.resetAuthorizations`, a call without parameters and with a Bool result.
    private func resetAuthorizationsTl() throws -> [UInt8] {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let method: ImpulseMappingMethod = try XCTUnwrap(mapping.method(name: "auth.resetAuthorizations"))
        return withUnsafeBytes(of: method.id.littleEndian) { (buffer: UnsafeRawBufferPointer) -> [UInt8] in
            return Array(buffer)
        }
    }


    /// Sends one call and waits for its completion.
    private func perform(
        session: ImpulseNetworkSession,
        tl: [UInt8],
        options: ImpulseRequestOptions = ImpulseRequestOptions(),
        parse: @escaping ([UInt8]) -> Any?,
        acknowledged: (() -> Void)?
    ) async -> Result<ImpulseNetworkResponse, ImpulseRequestFailure> {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<ImpulseNetworkResponse, ImpulseRequestFailure>, Never>) -> Void in
            let request: ImpulseNetworkRequest = ImpulseNetworkRequest(
                tl: tl,
                options: options,
                acknowledged: acknowledged,
                parse: parse,
                completed: { (result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void in
                    continuation.resume(returning: result)
                }
            )
            _ = session.add(request)
        }
    }


    private func successValue(_ result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Any? {
        if case .success(let response) = result {
            return response.result
        }
        return nil
    }


    private func failureValue(_ result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> ImpulseRequestFailure? {
        if case .failure(let failure) = result {
            return failure
        }
        return nil
    }


    // MARK: Roles and datacenters


    func testMainSessionKeepsRoleAndDatacenter() throws {
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .success([]),
            delegate: nil
        )

        XCTAssertEqual(session.role, .main)
        XCTAssertEqual(session.datacenterId, 4)
    }


    func testWorkerSessionKeepsMasterAndTransferKind() throws {
        let role: ImpulseSessionRole = .worker(masterDatacenterId: 2, isMedia: true, isCdn: false)
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 5,
            role: role,
            reply: .success([]),
            delegate: nil
        )

        XCTAssertEqual(session.role, role)
        XCTAssertEqual(session.datacenterId, 5)
    }


    func testAnyDatacenterIdIsAccepted() throws {
        let identifiers: [Int] = [1, 2, 3, 4, 5, 203, 10_001]
        for identifier: Int in identifiers {
            let session: ImpulseNetworkSession = try makeSession(
                datacenterId: identifier,
                role: .worker(masterDatacenterId: 1, isMedia: false, isCdn: false),
                reply: .success([]),
                delegate: nil
            )
            XCTAssertEqual(session.datacenterId, identifier)
        }
    }


    // MARK: Requests


    func testReplyIsParsedIntoResult() async throws {
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .success([0x08, 0x01]),
            delegate: nil
        )

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: nil
        )

        XCTAssertEqual(self.successValue(outcome) as? String, "parsed")
    }


    func testAcknowledgedFiresOnceWhenSent() async throws {
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .success([0x08, 0x01]),
            delegate: nil
        )
        let acknowledgements: NetworkSessionCounter = NetworkSessionCounter()

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: {
                acknowledgements.increment()
            }
        )

        XCTAssertNotNil(self.successValue(outcome))
        XCTAssertEqual(acknowledgements.value(), 1)
    }


    func testNilParseCompletesWithTlParsingError() async throws {
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .success([0x08, 0x01]),
            delegate: nil
        )

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return nil
            },
            acknowledged: nil
        )

        XCTAssertEqual(self.failureValue(outcome), ImpulseRequestFailure.rpc(ImpulseNetworkSession.tlParsingError))
        XCTAssertEqual(ImpulseNetworkSession.tlParsingError.code, 500)
        XCTAssertEqual(ImpulseNetworkSession.tlParsingError.text, "TL_PARSING_ERROR")
    }


    /// Without a total deadline a network failure is retried, as on Android. The carrier answers the third send as
    /// cancelled, which ends the call, so the test is bounded by its script.
    func testNetworkFailureIsRetriedWithoutDeadline() async throws {
        let carrierFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
        let cancelledFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: networkSessionCancelledCode,
            appCode: 0,
            appType: "",
            metadata: [:]
        )
        let clock: NetworkSessionClock = NetworkSessionClock()
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            replies: [.failure(carrierFailure), .failure(carrierFailure), .failure(cancelledFailure)],
            delegate: nil,
            clock: clock
        )

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: nil
        )

        XCTAssertEqual(self.failureValue(outcome), .canceled)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2])
    }


    /// With a total deadline a network failure is delivered as a network failure once the deadline passes, never as an
    /// RPC error. The waits of 1 and 2 seconds end exactly at the 3-second deadline, so no third send starts.
    func testNetworkFailureIsDeliveredAsNetworkNotRpc() async throws {
        let carrierFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
        let clock: NetworkSessionClock = NetworkSessionClock()
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            replies: [.failure(carrierFailure), .failure(carrierFailure), .failure(carrierFailure)],
            delegate: nil,
            clock: clock
        )

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            options: ImpulseRequestOptions(totalDeadlineSeconds: 3),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: nil
        )

        guard case .some(.network(let failure)) = self.failureValue(outcome) else {
            XCTFail("a carrier failure without a server answer must be a network failure at the deadline")
            return
        }
        XCTAssertEqual(failure, carrierFailure)
        XCTAssertEqual(clock.waitedSeconds(), [1, 2])
        XCTAssertEqual(clock.nowSeconds(), 3)
    }


    func testAuthorizationFailureNotifiesMainDelegate() async throws {
        let carrierFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 401, appType: "AUTH_TEST", metadata: [:])
        let delegate: NetworkSessionDelegateSpy = NetworkSessionDelegateSpy()
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .failure(carrierFailure),
            delegate: delegate
        )

        let outcome: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: nil
        )

        XCTAssertEqual(self.failureValue(outcome), ImpulseRequestFailure.rpc(ImpulseRpcError(code: 401, text: "AUTH_TEST", temporary: false)))
        XCTAssertEqual(delegate.authorizationCount(), 1)
    }


    func testWorkerAuthorizationFailureDoesNotNotifyDelegate() async throws {
        let carrierFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 0, appCode: 401, appType: "AUTH_TEST", metadata: [:])
        let delegate: NetworkSessionDelegateSpy = NetworkSessionDelegateSpy()
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .worker(masterDatacenterId: 4, isMedia: false, isCdn: false),
            reply: .failure(carrierFailure),
            delegate: delegate
        )

        _ = await self.perform(
            session: session,
            tl: try resetAuthorizationsTl(),
            parse: { (_: [UInt8]) -> Any? in
                return "parsed"
            },
            acknowledged: nil
        )

        XCTAssertEqual(delegate.authorizationCount(), 0)
    }


    // MARK: Lifecycle


    func testStoppedSessionRefusesNewCalls() throws {
        let session: ImpulseNetworkSession = try makeSession(
            datacenterId: 4,
            role: .main,
            reply: .success([0x08, 0x01]),
            delegate: nil
        )
        session.stop()

        let call: ImpulseRequestCall? = session.add(
            ImpulseNetworkRequest(
                tl: try resetAuthorizationsTl(),
                parse: { (_: [UInt8]) -> Any? in
                    return "parsed"
                },
                completed: { (_: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void in
                }
            )
        )

        XCTAssertNil(call)
    }


    // MARK: Socket policy


    func testSocketPolicyValues() {
        XCTAssertEqual(ImpulseSocketPolicy.minReconnectDelaySeconds, 1)
        XCTAssertEqual(ImpulseSocketPolicy.maxReconnectDelaySeconds, 30)
        XCTAssertEqual(ImpulseSocketPolicy.maxServerPingDelaySeconds, 10)
    }
}
