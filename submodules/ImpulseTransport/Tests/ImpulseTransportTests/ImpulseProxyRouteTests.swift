import XCTest
@testable import ImpulseTransport


private final class FakeProxyRouteObservation: ImpulseProxyRouteObservation {
    private let owner: FakeProxyRouteSource
    private let identifier: Int


    init(
        owner: FakeProxyRouteSource,
        identifier: Int
    ) {
        self.owner = owner
        self.identifier = identifier
    }


    func cancel() {
        owner.removeHandler(identifier: identifier)
    }
}


private final class FakeProxyRouteSource: ImpulseProxyRouteSource, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var route: ImpulseProxyRoute?
    private var epoch: Int = 0
    private var nextIdentifier: Int = 0
    private var handlers: [Int: @Sendable (Int) -> Void] = [:]


    init(route: ImpulseProxyRoute?) {
        self.route = route
    }


    var currentRoute: ImpulseProxyRoute? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return route
    }


    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation {
        lock.lock()
        let identifier: Int = nextIdentifier
        nextIdentifier += 1
        handlers[identifier] = handler
        lock.unlock()
        return FakeProxyRouteObservation(owner: self, identifier: identifier)
    }


    func setRoute(_ newRoute: ImpulseProxyRoute?) {
        lock.lock()
        route = newRoute
        epoch += 1
        let currentEpoch: Int = epoch
        let currentHandlers: [@Sendable (Int) -> Void] = Array(handlers.values)
        lock.unlock()
        for handler: @Sendable (Int) -> Void in currentHandlers {
            handler(currentEpoch)
        }
    }


    func removeHandler(identifier: Int) {
        lock.lock()
        handlers[identifier] = nil
        lock.unlock()
    }
}


private final class EpochRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [Int] = []


    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }


    func snapshot() -> [Int] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return values
    }
}


final class ImpulseProxyRouteTests: XCTestCase {
    func testRouteKeepsHostPortAndCredentials() {
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        XCTAssertEqual(route.host, "127.0.0.1")
        XCTAssertEqual(route.port, 1080)
        XCTAssertEqual(route.username, "user")
        XCTAssertEqual(route.password, "secret")
    }


    func testRoutesWithSameFieldsAreEqual() {
        let first: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        let second: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        let other: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 10, username: nil, password: nil)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
    }


    func testSourceWithoutRouteReportsDirect() {
        let source: FakeProxyRouteSource = FakeProxyRouteSource(route: nil)
        XCTAssertNil(source.currentRoute)
    }


    func testSourceReportsTheRouteSetLast() {
        let source: FakeProxyRouteSource = FakeProxyRouteSource(route: nil)
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        source.setRoute(route)
        XCTAssertEqual(source.currentRoute, route)
        source.setRoute(nil)
        XCTAssertNil(source.currentRoute)
    }


    func testEachChangeDeliversExactlyOnce() {
        let source: FakeProxyRouteSource = FakeProxyRouteSource(route: nil)
        let recorder: EpochRecorder = EpochRecorder()
        let observation: ImpulseProxyRouteObservation = source.observe { (epoch: Int) in
            recorder.append(epoch)
        }
        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        source.setRoute(nil)
        XCTAssertEqual(recorder.snapshot(), [1, 2])
        observation.cancel()
    }


    func testCancelledObservationNeverDelivers() {
        let source: FakeProxyRouteSource = FakeProxyRouteSource(route: nil)
        let recorder: EpochRecorder = EpochRecorder()
        let observation: ImpulseProxyRouteObservation = source.observe { (epoch: Int) in
            recorder.append(epoch)
        }
        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        observation.cancel()
        source.setRoute(nil)
        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil))
        XCTAssertEqual(recorder.snapshot(), [1])
    }


    func testCancelTwiceIsSafe() {
        let source: FakeProxyRouteSource = FakeProxyRouteSource(route: nil)
        let recorder: EpochRecorder = EpochRecorder()
        let observation: ImpulseProxyRouteObservation = source.observe { (epoch: Int) in
            recorder.append(epoch)
        }
        observation.cancel()
        observation.cancel()
        source.setRoute(nil)
        XCTAssertEqual(recorder.snapshot(), [])
    }
}
