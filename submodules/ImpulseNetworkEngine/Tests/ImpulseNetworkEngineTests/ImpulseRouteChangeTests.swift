import XCTest
import ImpulseTransport
@testable import ImpulseNetworkEngine


/// The names of the calls that the route epochs make on the parts, as the log records them.
private enum ImpulseRouteChangeEntry {
    static let socketConnect: String = "socket.connect"
    static let socketDisconnect: String = "socket.disconnect"
    static let poolStart: String = "pool.start"
    static let poolStop: String = "pool.stop"
    static let poolResetMain: String = "pool.resetMain"
    static let fleetReset: String = "fleet.reset"
    static let epochAdvance: String = "epoch.advance"
}


/// The calls the route epochs make on the parts, in the order they arrive.
private final class ImpulseRouteChangeLog: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var entries: [String] = []


    func record(_ entry: String) {
        self.lock.lock()
        self.entries.append(entry)
        self.lock.unlock()
    }


    func count(_ entry: String) -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries.filter { (value: String) -> Bool in
            return value == entry
        }.count
    }
}


private final class ImpulseRouteChangeSocket: ImpulseRouteUpdateSocket {
    private let log: ImpulseRouteChangeLog


    init(log: ImpulseRouteChangeLog) {
        self.log = log
    }


    func connect() {
        self.log.record(ImpulseRouteChangeEntry.socketConnect)
    }


    func disconnect() {
        self.log.record(ImpulseRouteChangeEntry.socketDisconnect)
    }
}


private final class ImpulseRouteChangePool: ImpulseRoutePool {
    private let log: ImpulseRouteChangeLog


    init(log: ImpulseRouteChangeLog) {
        self.log = log
    }


    func start() {
        self.log.record(ImpulseRouteChangeEntry.poolStart)
    }


    func stop() {
        self.log.record(ImpulseRouteChangeEntry.poolStop)
    }


    func resetMain() {
        self.log.record(ImpulseRouteChangeEntry.poolResetMain)
    }
}


private final class ImpulseRouteChangeFleet: ImpulseRouteMediaFleet {
    private let log: ImpulseRouteChangeLog


    init(log: ImpulseRouteChangeLog) {
        self.log = log
    }


    func reset() {
        self.log.record(ImpulseRouteChangeEntry.fleetReset)
    }
}


/// The epoch sink of the cases that do not send a request: it only records the advance.
private final class ImpulseRouteChangeEpochSink: ImpulseRouteEpochSink {
    private let log: ImpulseRouteChangeLog


    init(log: ImpulseRouteChangeLog) {
        self.log = log
    }


    func advanceRouteEpoch() {
        self.log.record(ImpulseRouteChangeEntry.epochAdvance)
    }
}


/// The epoch sink of the cases that send a request: the real request service, which advances its own route epoch, and the
/// log records the advance as the other sinks do.
private final class ImpulseRouteChangeServiceSink: ImpulseRouteEpochSink {
    private let service: ImpulseRequestService
    private let log: ImpulseRouteChangeLog


    init(
        service: ImpulseRequestService,
        log: ImpulseRouteChangeLog
    ) {
        self.service = service
        self.log = log
    }


    func advanceRouteEpoch() {
        self.log.record(ImpulseRouteChangeEntry.epochAdvance)
        self.service.advanceRouteEpoch()
    }
}


/// One subscription to the route epochs. A cancelled subscription receives nothing.
private final class ImpulseRouteChangeObservation: ImpulseProxyRouteObservation {
    let handler: @Sendable (Int) -> Void
    private let lock: NSLock = NSLock()
    private var cancelled: Bool = false


    init(handler: @escaping @Sendable (Int) -> Void) {
        self.handler = handler
    }


    func cancel() {
        self.lock.lock()
        self.cancelled = true
        self.lock.unlock()
    }


    func isCancelled() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.cancelled
    }
}


/// A route source that the test drives: `deliver` sends an epoch to every subscription that is not cancelled.
private final class ImpulseRouteChangeSource: ImpulseProxyRouteSource, @unchecked Sendable {
    let currentRoute: ImpulseProxyRoute? = nil
    private let lock: NSLock = NSLock()
    private var observations: [ImpulseRouteChangeObservation] = []


    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation {
        let observation: ImpulseRouteChangeObservation = ImpulseRouteChangeObservation(handler: handler)
        self.lock.lock()
        self.observations.append(observation)
        self.lock.unlock()
        return observation
    }


    func deliver(epoch: Int) {
        self.lock.lock()
        let live: [ImpulseRouteChangeObservation] = self.observations.filter { (observation: ImpulseRouteChangeObservation) -> Bool in
            return !observation.isCancelled()
        }
        self.lock.unlock()
        for observation: ImpulseRouteChangeObservation in live {
            observation.handler(epoch)
        }
    }


    func subscriptionCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.observations.count
    }


    func cancelledCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.observations.filter { (observation: ImpulseRouteChangeObservation) -> Bool in
            return observation.isCancelled()
        }.count
    }
}


/// A clock that moves only when the service waits, so no retry waits in real time.
private final class ImpulseRouteChangeClock: ImpulseRequestClock, @unchecked Sendable {
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


private final class ImpulseRouteChangeSession: ImpulseRequestSession, @unchecked Sendable {
    private let loggedIn: Bool


    init(loggedIn: Bool) {
        self.loggedIn = loggedIn
    }


    func hasSession() async -> Bool {
        return self.loggedIn
    }


    func needsProactiveRefresh() async -> Bool {
        return false
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        return .refreshed
    }
}


/// A carrier for the update route. Its first send delivers the route epoch 1 while the call is in flight, and it returns
/// only after the route queue of the root has applied that epoch. Later sends answer from the replies, and a send past the
/// replies succeeds with an empty reply.
private final class ImpulseRouteChangeCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private var sends: Int = 0
    private let source: ImpulseRouteChangeSource
    private weak var root: ImpulseNetworkCompositionRoot? = nil


    init(
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        source: ImpulseRouteChangeSource
    ) {
        self.replies = replies
        self.source = source
    }


    func attach(_ root: ImpulseNetworkCompositionRoot) {
        self.lock.lock()
        self.root = root
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
        let attached: ImpulseNetworkCompositionRoot? = self.root
        self.lock.unlock()

        if sendNumber == 1 {
            self.source.deliver(epoch: 1)
            attached?.routeQueue.sync {}
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


private func routeChangeRequest(method: String) -> ImpulseEncodedRequest {
    return ImpulseEncodedRequest(
        methodId: 1,
        method: method,
        path: "/" + method,
        proto: [1, 2, 3],
        takeoutId: nil
    )
}


private func routeChangeNetworkFailure() -> Result<[UInt8], ImpulseCarrierFailure> {
    return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
}


private func isCanceled(_ result: Result<[UInt8], ImpulseRequestFailure>) -> Bool {
    switch result {
    case .success:
        return false

    case .failure(let failure):
        if case .canceled = failure {
            return true
        }
        return false
    }
}


/// Builds a root whose update socket, pool and media fleet are fakes that record their calls in `log`, and whose route
/// source is `source`. Nothing connects: the root is not started, and only the route observation is run by the tests.
private func makeRouteRoot(
    source: ImpulseRouteChangeSource,
    log: ImpulseRouteChangeLog,
    epochSink: any ImpulseRouteEpochSink
) throws -> ImpulseNetworkCompositionRoot {
    let inputs: ImpulseNetworkCompositionInputs = ImpulseNetworkCompositionInputs(
        endpoints: try ImpulseEndpoints(),
        mapping: try ImpulseMapping.loadBundled(),
        keychain: ImpulseFactoryKeychain(),
        keychainAccessGroup: "test.group",
        identityClock: ImpulseFactoryClock(),
        identityScheduler: ImpulseFactoryScheduler(),
        declaration: ImpulseNetworkEngineFactory.makeDeclaration(),
        updateBridge: ImpulseUpdateBridge(context: impulseMakeContext()),
        routeSource: source
    )
    let seams: ImpulseNetworkRouteSeams = ImpulseNetworkRouteSeams(
        updateSocket: ImpulseRouteChangeSocket(log: log),
        pool: ImpulseRouteChangePool(log: log),
        mediaFleet: ImpulseRouteChangeFleet(log: log),
        epochSink: epochSink
    )
    return try ImpulseNetworkCompositionRoot(inputs: inputs, seams: seams)
}


final class ImpulseRouteChangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ImpulseEngineTestLogger.install()
    }


    /// One route epoch advances the request service, resets the pool main and the media fleet, and reconnects the update
    /// socket exactly once: a disconnect and then one connect over the new route.
    func testOneEpochReconnectsTheUpdateSocketOnce() throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeEpochSink(log: log)
        )
        root.startRouteObservation()

        source.deliver(epoch: 1)
        root.routeQueue.sync {}

        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketConnect), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketDisconnect), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.epochAdvance), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.poolResetMain), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.fleetReset), 1)
        withExtendedLifetime(root) {}
    }


    /// A repeated epoch and an older epoch change nothing: the socket still reconnected once, for the first epoch only.
    func testRepeatedEpochIsIgnored() throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeEpochSink(log: log)
        )
        root.startRouteObservation()

        source.deliver(epoch: 1)
        root.routeQueue.sync {}
        source.deliver(epoch: 1)
        source.deliver(epoch: 0)
        root.routeQueue.sync {}

        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketConnect), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.epochAdvance), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.poolResetMain), 1)
        withExtendedLifetime(root) {}
    }


    /// A request in flight at the epoch completes once with its reply. Its send fails with a network failure after the
    /// epoch advanced, so the failure is a route failure: it waits the policy delay of its first attempt (one second), spends
    /// no budget, and the next send succeeds.
    func testRequestInFlightAtTheEpochCompletesOnceWithoutSpendingBudget() async throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let carrier: ImpulseRouteChangeCarrier = ImpulseRouteChangeCarrier(
            replies: [routeChangeNetworkFailure(), .success([7])],
            source: source
        )
        let clock: ImpulseRouteChangeClock = ImpulseRouteChangeClock()
        let service: ImpulseRequestService = ImpulseRequestService(
            session: ImpulseRouteChangeSession(loggedIn: true),
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: true,
            onAuthorizationRequired: {
            },
            clock: clock
        )
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeServiceSink(service: service, log: log)
        )
        carrier.attach(root)
        root.startRouteObservation()

        let result: Result<[UInt8], ImpulseRequestFailure> = await service.execute(
            request: routeChangeRequest(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )

        XCTAssertEqual(try? result.get(), [7])
        XCTAssertEqual(carrier.sendCount(), 2)
        XCTAssertEqual(clock.waitedSeconds(), [1])
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketConnect), 1)
        withExtendedLifetime(root) {}
    }


    /// A request cancelled before the epoch settles once as canceled and is never sent, and the epoch that follows does not
    /// revive it: no send, no wait, and no retry happen after the cancel.
    func testRequestCancelledBeforeTheEpochSettlesAsCanceled() async throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let carrier: ImpulseRouteChangeCarrier = ImpulseRouteChangeCarrier(replies: [], source: source)
        let clock: ImpulseRouteChangeClock = ImpulseRouteChangeClock()
        let service: ImpulseRequestService = ImpulseRequestService(
            session: ImpulseRouteChangeSession(loggedIn: false),
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: false,
            onAuthorizationRequired: {
            },
            clock: clock
        )
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeServiceSink(service: service, log: log)
        )
        carrier.attach(root)
        root.startRouteObservation()

        let call: ImpulseRequestCall = service.submit(
            request: routeChangeRequest(method: "messages.sendMessage"),
            options: ImpulseRequestOptions()
        )
        call.cancel()
        source.deliver(epoch: 1)
        root.routeQueue.sync {}
        let result: Result<[UInt8], ImpulseRequestFailure> = await call.result.value

        XCTAssertTrue(isCanceled(result))
        XCTAssertEqual(carrier.sendCount(), 0)
        XCTAssertEqual(clock.waitedSeconds(), [])
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.epochAdvance), 1)
        withExtendedLifetime(root) {}
    }


    /// Stopping the root cancels its route observation, and the pool and the update socket stop with it. An epoch
    /// delivered after the stop reaches nobody: the socket does not connect and the request service does not advance.
    func testStopCancelsTheRouteObservation() throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeEpochSink(log: log)
        )
        root.startRouteObservation()
        XCTAssertEqual(source.subscriptionCount(), 1)

        root.stop()
        XCTAssertEqual(source.cancelledCount(), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.poolStop), 1)

        source.deliver(epoch: 1)
        root.routeQueue.sync {}

        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketConnect), 0)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.epochAdvance), 0)
        withExtendedLifetime(root) {}
    }


    /// A route change while the sessions are paused does not connect the update socket: the pause leaves it down, and it
    /// connects on resume over the current route. The request service and the pool still advance and reset.
    func testRouteChangeWhilePausedDoesNotConnect() throws {
        let log: ImpulseRouteChangeLog = ImpulseRouteChangeLog()
        let source: ImpulseRouteChangeSource = ImpulseRouteChangeSource()
        let root: ImpulseNetworkCompositionRoot = try makeRouteRoot(
            source: source,
            log: log,
            epochSink: ImpulseRouteChangeEpochSink(log: log)
        )
        root.startRouteObservation()
        root.setPaused(true)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketDisconnect), 1)

        source.deliver(epoch: 1)
        root.routeQueue.sync {}

        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketConnect), 0)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.socketDisconnect), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.epochAdvance), 1)
        XCTAssertEqual(log.count(ImpulseRouteChangeEntry.poolResetMain), 1)
        withExtendedLifetime(root) {}
    }
}
