import XCTest
@testable import ImpulseProxy

final class HealthPolicyTests: XCTestCase {
    func testStaleCheckStopsWhateverTheCoreState() {
        let retriedValues: [Bool] = [false, true]
        let aliveValues: [Bool] = [false, true]
        for retried: Bool in retriedValues {
            for alive: Bool in aliveValues {
                let action: HealthAction = HealthPolicy.decide(
                    current: false,
                    alreadyRetried: retried,
                    alive: alive
                )
                XCTAssertEqual(action, .stop)
            }
        }
    }


    func testAliveCoreRechecksAndClearsRetryAllowance() {
        let retriedValues: [Bool] = [false, true]
        for retried: Bool in retriedValues {
            let action: HealthAction = HealthPolicy.decide(
                current: true,
                alreadyRetried: retried,
                alive: true
            )
            XCTAssertEqual(action, .recheck)
        }
    }


    func testFirstDeathRestartsOnce() {
        let action: HealthAction = HealthPolicy.decide(
            current: true,
            alreadyRetried: false,
            alive: false
        )
        XCTAssertEqual(action, .restart)
    }


    func testDeathAfterRestartFails() {
        let action: HealthAction = HealthPolicy.decide(
            current: true,
            alreadyRetried: true,
            alive: false
        )
        XCTAssertEqual(action, .fail)
    }


    func testHealthCheckRunsEveryThirtySeconds() {
        XCTAssertEqual(HealthPolicy.checkIntervalSeconds, 30)
    }


    func testFailureReportsCoreStopped() {
        XCTAssertEqual(HealthPolicy.coreStoppedError, "err:coreStopped")
    }
}
