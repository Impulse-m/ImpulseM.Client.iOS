import Foundation
import XCTest
@testable import ImpulseProxy


/// Failure scripted into one step of the fake core.
enum FakeCoreError: Error {
    case scripted(
        step: String
    )
}


/// Scripted libXray driver. It records every call and can fail one named step. A stop gate, when set,
/// blocks the stop call until the test signals it or the bounded wait expires.
final class FakeXrayCoreDriver: XrayCoreDriver, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var recordedCalls: [String] = []
    private var runningValue: Bool = false
    private var portValues: [Int] = [41001, 41002]
    private var failingStep: String?
    private var stopGate: DispatchSemaphore?
    private var lastConfigValue: String?


    var calls: [String] {
        return locked { () -> [String] in
            return recordedCalls
        }
    }


    var lastConfig: String? {
        return locked { () -> String? in
            return lastConfigValue
        }
    }


    func setRunning(
        _ value: Bool
    ) {
        locked { () -> Void in
            runningValue = value
        }
    }


    func setPorts(
        _ value: [Int]
    ) {
        locked { () -> Void in
            portValues = value
        }
    }


    func failStep(
        _ step: String?
    ) {
        locked { () -> Void in
            failingStep = step
        }
    }


    func setStopGate(
        _ gate: DispatchSemaphore?
    ) {
        locked { () -> Void in
            stopGate = gate
        }
    }


    func isRunning() throws -> Bool {
        return locked { () -> Bool in
            recordedCalls.append("isRunning")
            return runningValue
        }
    }


    func stop() throws {
        record("stop")
        let gate: DispatchSemaphore? = locked { () -> DispatchSemaphore? in
            return stopGate
        }
        if let waitGate: DispatchSemaphore = gate {
            _ = waitGate.wait(timeout: .now() + 5)
        }
        try failIfScripted("stop")
        locked { () -> Void in
            runningValue = false
        }
    }


    func freePorts(
        count: Int
    ) throws -> [Int] {
        record("freePorts")
        try failIfScripted("freePorts")
        return locked { () -> [Int] in
            return portValues
        }
    }


    func test(
        configJSON: String
    ) throws {
        record("test")
        locked { () -> Void in
            lastConfigValue = configJSON
        }
        try failIfScripted("test")
    }


    func run(
        configJSON: String
    ) throws {
        record("run")
        try failIfScripted("run")
        locked { () -> Void in
            runningValue = true
        }
    }


    private func record(
        _ call: String
    ) {
        locked { () -> Void in
            recordedCalls.append(call)
        }
    }


    private func failIfScripted(
        _ step: String
    ) throws {
        let shouldFail: Bool = locked { () -> Bool in
            return failingStep == step
        }
        if shouldFail {
            throw FakeCoreError.scripted(step: step)
        }
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


/// Records the health checks the controller schedules instead of waiting for them. The test runs them by hand.
final class FakeHealthScheduler: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private var delayValues: [Double] = []


    var pendingCount: Int {
        return locked { () -> Int in
            return pending.count
        }
    }


    var delays: [Double] {
        return locked { () -> [Double] in
            return delayValues
        }
    }


    func schedule(
        _ delaySeconds: Double,
        _ work: @escaping @Sendable () -> Void
    ) {
        locked { () -> Void in
            delayValues.append(delaySeconds)
            pending.append(work)
        }
    }


    /// Runs the oldest pending check on the calling thread. Returns false when none is pending.
    @discardableResult
    func runNext() -> Bool {
        let work: (@Sendable () -> Void)? = locked { () -> (@Sendable () -> Void)? in
            if pending.isEmpty {
                return nil
            }
            return pending.removeFirst()
        }
        guard let run: @Sendable () -> Void = work else {
            return false
        }
        run()
        return true
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


/// Records every epoch the controller publishes to its observer.
final class EpochRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [Int] = []


    var count: Int {
        return locked { () -> Int in
            return values.count
        }
    }


    func record(
        _ epoch: Int
    ) {
        locked { () -> Void in
            values.append(epoch)
        }
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


/// Records every status the controller publishes to its status observer.
final class StatusRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var recorded: [ProxyStatus] = []


    var values: [ProxyStatus] {
        return locked { () -> [ProxyStatus] in
            return recorded
        }
    }


    func record(
        _ status: ProxyStatus
    ) {
        locked { () -> Void in
            recorded.append(status)
        }
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}


final class ProxyControllerTests: XCTestCase {
    private static let validOutbound: String = #"{"protocol":"vless","tag":"proxy","settings":{"vnext":[{"address":"h.example","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"a"}}}"#


    func testOffWhenDisabledOnlyProbesTheCore() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: false, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .off)
        XCTAssertEqual(driver.calls, ["isRunning"])
        XCTAssertEqual(controller.route, .direct)
        XCTAssertNil(controller.runtime)
    }


    func testFailedWithoutSelectedServerReportsNoServer() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: nil),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:noServer")
        XCTAssertEqual(driver.calls, ["isRunning"])
        XCTAssertEqual(controller.route, .blocked)
    }


    func testRestartSequenceRunsInOrderAndPublishesLoopbackRuntime() throws {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(driver.calls, ["isRunning", "freePorts", "test", "run"])
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(controller.route, .proxy)
        let runtime: ProxyRuntime = try XCTUnwrap(controller.runtime)
        XCTAssertEqual(runtime.httpAccess.endpoint.host, "127.0.0.1")
        XCTAssertEqual(runtime.httpAccess.endpoint.port, 41001)
        XCTAssertEqual(runtime.socksEndpoint.host, "127.0.0.1")
        XCTAssertEqual(runtime.socksEndpoint.port, 41002)
        XCTAssertEqual(runtime.httpAccess.credentials.user.count, 32)
        XCTAssertEqual(runtime.httpAccess.credentials.password.count, 48)
        XCTAssertTrue(runtime.httpAccess.credentials.user.allSatisfy { (character: Character) -> Bool in
            return character.isHexDigit
        })
        XCTAssertTrue(runtime.httpAccess.credentials.password.allSatisfy { (character: Character) -> Bool in
            return character.isHexDigit
        })
        let config: String = try XCTUnwrap(driver.lastConfig)
        XCTAssertTrue(config.contains("41001"))
        XCTAssertEqual(scheduler.delays, [30])
    }


    func testInvalidConfigWhenTestFailsAndCoreIsNotRun() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        driver.failStep("test")
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:invalidConfig")
        XCTAssertNil(controller.runtime)
        XCTAssertFalse(driver.calls.contains("run"))
        XCTAssertEqual(scheduler.pendingCount, 0)
    }


    func testCoreStartWhenRunFails() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        driver.failStep("run")
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:coreStart")
        XCTAssertNil(controller.runtime)
    }


    func testCoreStartWhenPortsCannotBeAllocated() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        driver.setPorts([41001])
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:coreStart")
        XCTAssertFalse(driver.calls.contains("test"))
    }


    func testInvalidOutboundGivesInvalidConfigBeforeTheTest() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let server: ImpulseProxyState.Server = ImpulseProxyState.Server(
            id: "a",
            name: "Broken",
            host: "example.com",
            port: 443,
            network: "tcp",
            security: "none",
            outboundJson: "not json"
        )
        let state: ImpulseProxyState = ImpulseProxyState(
            enabled: true,
            selectedId: "a",
            manual: [server]
        )
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: state,
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:invalidConfig")
        XCTAssertFalse(driver.calls.contains("test"))
    }


    func testUpdateClearsRuntimeAtOnceAndRestartsOnServerChange() throws {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a", serverIds: ["a", "b"]),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        let firstUser: String = try XCTUnwrap(controller.runtime?.httpAccess.credentials.user)
        let gate: DispatchSemaphore = DispatchSemaphore(value: 0)
        driver.setStopGate(gate)
        let epochBefore: Int = controller.epoch
        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.selectedId = "b"
        }
        XCTAssertNil(controller.runtime)
        XCTAssertEqual(controller.status, .starting)
        XCTAssertGreaterThan(controller.epoch, epochBefore)
        gate.signal()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 2)
        let secondUser: String = try XCTUnwrap(controller.runtime?.httpAccess.credentials.user)
        XCTAssertNotEqual(secondUser, firstUser)
    }


    func testPingOnlyChangeDoesNotRestartTheCore() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        let callsBefore: [String] = driver.calls
        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.advanced.pingTimeoutSeconds = 9
        }
        controller.drainWorker()
        XCTAssertEqual(driver.calls, callsBefore)
        XCTAssertEqual(controller.status, .running)
    }


    func testCoreAffectingAdvancedChangeRestartsTheCore() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.advanced.muxEnabled = true
        }
        controller.drainWorker()
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 2)
        XCTAssertEqual(controller.status, .running)
    }


    func testHealthCheckRestartsOnceThenFailsClosed() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(scheduler.pendingCount, 1)

        driver.setRunning(false)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)

        driver.setRunning(false)
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.lastError, "err:coreStopped")
        XCTAssertNil(controller.runtime)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }


    func testHealthyCoreRechecksAfterThirtySeconds() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(scheduler.delays, [30, 30])
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 1)
    }


    func testStopCoreCancelsTheHealthCheckAndRestartCoreRunsTheSequence() throws {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        try controller.stopCore()
        XCTAssertNil(controller.runtime)
        XCTAssertEqual(controller.status, .starting)
        XCTAssertEqual(controller.route, .blocked)

        XCTAssertTrue(scheduler.runNext())
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 1)
        XCTAssertEqual(controller.status, .starting)

        controller.restartCore()
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(driver.calls.filter { (call: String) -> Bool in
            return call == "freePorts"
        }.count, 2)
    }


    func testEpochChangesOnRouteOrRuntimeOnly() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let recorder: EpochRecorder = EpochRecorder()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.observeEpoch { (epoch: Int) -> Void in
            recorder.record(epoch)
        }
        controller.startIfEnabled()
        controller.drainWorker()
        let afterStart: Int = recorder.count
        XCTAssertGreaterThan(afterStart, 0)

        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.advanced.pingTimeoutSeconds = 7
        }
        XCTAssertEqual(recorder.count, afterStart)

        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.enabled = false
        }
        controller.drainWorker()
        XCTAssertGreaterThan(recorder.count, afterStart)
        XCTAssertEqual(controller.route, .direct)
        XCTAssertEqual(controller.status, .off)
    }


    func testRandomnessGivesDifferentCredentialsPerStart() throws {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.startIfEnabled()
        controller.drainWorker()
        let first: String = try XCTUnwrap(controller.runtime?.httpAccess.credentials.password)
        controller.restartCore()
        let second: String = try XCTUnwrap(controller.runtime?.httpAccess.credentials.password)
        XCTAssertNotEqual(first, second)
    }


    func testStatusObserverSeesOffStartingRunningAndFailed() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let recorder: StatusRecorder = StatusRecorder()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        controller.observeStatus { (status: ProxyStatus) -> Void in
            recorder.record(status)
        }
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(recorder.values, [.running])

        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.enabled = false
        }
        controller.drainWorker()
        XCTAssertEqual(recorder.values, [.running, .starting, .off])

        controller.update { (next: inout ImpulseProxyState) -> Void in
            next.enabled = true
            next.selectedId = nil
        }
        controller.drainWorker()
        XCTAssertEqual(recorder.values, [.running, .starting, .off, .starting, .failed])
    }


    func testStartingToFailedReachesStatusObserverWithoutAnEpoch() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let epochRecorder: EpochRecorder = EpochRecorder()
        let statusRecorder: StatusRecorder = StatusRecorder()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: nil),
            driver: driver,
            scheduler: scheduler
        )
        controller.observeEpoch { (epoch: Int) -> Void in
            epochRecorder.record(epoch)
        }
        controller.observeStatus { (status: ProxyStatus) -> Void in
            statusRecorder.record(status)
        }
        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .failed)
        XCTAssertEqual(controller.route, .blocked)
        XCTAssertNil(controller.runtime)
        XCTAssertEqual(epochRecorder.count, 0)
        XCTAssertEqual(statusRecorder.values, [.failed])
    }


    func testCancelledObservationsGetNoFurtherChanges() {
        let driver: FakeXrayCoreDriver = FakeXrayCoreDriver()
        let scheduler: FakeHealthScheduler = FakeHealthScheduler()
        let cancelledEpochs: EpochRecorder = EpochRecorder()
        let cancelledStatuses: StatusRecorder = StatusRecorder()
        let keptStatuses: StatusRecorder = StatusRecorder()
        let controller: ProxyController = ProxyControllerTests.makeController(
            state: ProxyControllerTests.state(enabled: true, selectedId: "a"),
            driver: driver,
            scheduler: scheduler
        )
        let epochObservation: ProxyObservation = controller.observeEpoch { (epoch: Int) -> Void in
            cancelledEpochs.record(epoch)
        }
        let statusObservation: ProxyObservation = controller.observeStatus { (status: ProxyStatus) -> Void in
            cancelledStatuses.record(status)
        }
        controller.observeStatus { (status: ProxyStatus) -> Void in
            keptStatuses.record(status)
        }
        epochObservation.cancel()
        statusObservation.cancel()
        statusObservation.cancel()
        XCTAssertFalse(epochObservation.isActive)
        XCTAssertFalse(statusObservation.isActive)

        controller.startIfEnabled()
        controller.drainWorker()
        XCTAssertEqual(controller.status, .running)
        XCTAssertEqual(cancelledEpochs.count, 0)
        XCTAssertEqual(cancelledStatuses.values, [])
        XCTAssertEqual(keptStatuses.values, [.running])
    }


    private static func makeController(
        state: ImpulseProxyState,
        driver: FakeXrayCoreDriver,
        scheduler: FakeHealthScheduler
    ) -> ProxyController {
        return ProxyController(
            initialState: state,
            driver: driver,
            persist: { (_: ImpulseProxyState) -> Void in
            },
            scheduler: scheduler.schedule
        )
    }


    private static func state(
        enabled: Bool,
        selectedId: String?,
        serverIds: [String] = ["a"]
    ) -> ImpulseProxyState {
        let servers: [ImpulseProxyState.Server] = serverIds.map { (id: String) -> ImpulseProxyState.Server in
            return ImpulseProxyState.Server(
                id: id,
                name: "Server " + id,
                host: "h.example",
                port: 443,
                network: "tcp",
                security: "tls",
                outboundJson: validOutbound
            )
        }
        return ImpulseProxyState(
            enabled: enabled,
            selectedId: selectedId,
            manual: servers
        )
    }
}
