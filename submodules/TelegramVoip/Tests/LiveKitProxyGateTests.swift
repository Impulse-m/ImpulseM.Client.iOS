import XCTest
@testable import TelegramVoip


final class LiveKitProxyGateTests: XCTestCase {
    func testSpikeIsNotPassedByDefault() {
        XCTAssertFalse(LiveKitProxyGate().spikePassed)
        XCTAssertFalse(LiveKitProxyGate.defaultSpikePassed)
    }


    func testCallsToggleHiddenBeforeSpike() {
        XCTAssertFalse(LiveKitProxyGate().callsToggleVisible)
    }


    func testCallsToggleVisibleOnlyWhenSpikePassed() {
        XCTAssertTrue(LiveKitProxyGate(spikePassed: true).callsToggleVisible)
    }


    func testCallsOnAndCoreRunningStillDirectBeforeSpike() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: false)
        let route: LiveKitCallRoute = gate.route(
            proxyEnabled: true,
            useForCalls: true,
            coreRunning: true,
            relayFailed: false
        )
        XCTAssertEqual(route, .direct)
    }


    func testEveryInputIsDirectBeforeSpike() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: false)
        let flags: [Bool] = [false, true]
        for proxyEnabled: Bool in flags {
            for useForCalls: Bool in flags {
                for coreRunning: Bool in flags {
                    for relayFailed: Bool in flags {
                        let route: LiveKitCallRoute = gate.route(
                            proxyEnabled: proxyEnabled,
                            useForCalls: useForCalls,
                            coreRunning: coreRunning,
                            relayFailed: relayFailed
                        )
                        XCTAssertEqual(route, .direct)
                    }
                }
            }
        }
    }


    func testFailedRelayNeverFallsBackToDirect() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: true)
        let route: LiveKitCallRoute = gate.route(
            proxyEnabled: true,
            useForCalls: true,
            coreRunning: true,
            relayFailed: true
        )
        XCTAssertEqual(route, .blocked)
        XCTAssertNotEqual(route, .direct)
    }


    func testCoreNotRunningNeverFallsBackToDirect() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: true)
        let route: LiveKitCallRoute = gate.route(
            proxyEnabled: true,
            useForCalls: true,
            coreRunning: false,
            relayFailed: false
        )
        XCTAssertEqual(route, .blocked)
    }


    func testTunnelledWhenSpikePassedAndCoreRunning() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: true)
        let route: LiveKitCallRoute = gate.route(
            proxyEnabled: true,
            useForCalls: true,
            coreRunning: true,
            relayFailed: false
        )
        XCTAssertEqual(route, .tunnelled)
    }


    func testDirectWhenProxyOffOrCallsToggleOffAfterSpike() {
        let gate: LiveKitProxyGate = LiveKitProxyGate(spikePassed: true)
        let proxyOff: LiveKitCallRoute = gate.route(
            proxyEnabled: false,
            useForCalls: true,
            coreRunning: true,
            relayFailed: false
        )
        let callsOff: LiveKitCallRoute = gate.route(
            proxyEnabled: true,
            useForCalls: false,
            coreRunning: true,
            relayFailed: false
        )
        XCTAssertEqual(proxyOff, .direct)
        XCTAssertEqual(callsOff, .direct)
    }
}
