import XCTest
@testable import ImpulseProxy

final class ProxyRoutingTests: XCTestCase {
    private let boolValues: [Bool] = [false, true]


    func testDisabledProxyAlwaysGoesDirect() {
        for useForTransport: Bool in boolValues {
            for running: Bool in boolValues {
                let route: ProxyRoute = ProxyRouting.decide(
                    enabled: false,
                    useForTransport: useForTransport,
                    running: running
                )
                XCTAssertEqual(route, .direct)
            }
        }
    }


    func testTransportToggleOffAlwaysGoesDirect() {
        for enabled: Bool in boolValues {
            for running: Bool in boolValues {
                let route: ProxyRoute = ProxyRouting.decide(
                    enabled: enabled,
                    useForTransport: false,
                    running: running
                )
                XCTAssertEqual(route, .direct)
            }
        }
    }


    func testEnabledTransportWithRunningCoreGoesThroughProxy() {
        let route: ProxyRoute = ProxyRouting.decide(
            enabled: true,
            useForTransport: true,
            running: true
        )
        XCTAssertEqual(route, .proxy)
    }


    func testEnabledTransportWithStoppedCoreIsBlockedNeverDirect() {
        let route: ProxyRoute = ProxyRouting.decide(
            enabled: true,
            useForTransport: true,
            running: false
        )
        XCTAssertEqual(route, .blocked)
        XCTAssertNotEqual(route, .direct)
    }


    func testFullRoutingMatrix() {
        for enabled: Bool in boolValues {
            for useForTransport: Bool in boolValues {
                for running: Bool in boolValues {
                    let expected: ProxyRoute = expectedRoute(
                        enabled: enabled,
                        useForTransport: useForTransport,
                        running: running
                    )
                    let actual: ProxyRoute = ProxyRouting.decide(
                        enabled: enabled,
                        useForTransport: useForTransport,
                        running: running
                    )
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }


    func testCallTunnelIsOnlyForVlessEnabledAndCallsToggle() {
        for vlessFeature: Bool in boolValues {
            for enabled: Bool in boolValues {
                for useForCalls: Bool in boolValues {
                    let actual: Bool = ProxyRouting.tunnelCalls(
                        vlessFeature: vlessFeature,
                        enabled: enabled,
                        useForCalls: useForCalls
                    )
                    let expected: Bool = vlessFeature && enabled && useForCalls
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }


    func testCallTunnelDoesNotDependOnCoreRunning() {
        // The tunnel decision takes no running state: a stopped core keeps calls tunnelled, so they fail closed.
        let tunnelled: Bool = ProxyRouting.tunnelCalls(
            vlessFeature: true,
            enabled: true,
            useForCalls: true
        )
        XCTAssertTrue(tunnelled)
    }


    func testDirectRouteGivesNoProxyWhateverTheAccess() {
        let access: ProxyAccess = makeAccess()
        let withAccess: ProxySelection = ProxySelector.select(
            route: .direct,
            access: access
        )
        let withoutAccess: ProxySelection = ProxySelector.select(
            route: .direct,
            access: nil
        )
        XCTAssertEqual(withAccess, .direct)
        XCTAssertEqual(withoutAccess, .direct)
    }


    func testProxyRouteUsesLoopbackHttpEndpointWithBasicCredentials() {
        let access: ProxyAccess = makeAccess()
        let selection: ProxySelection = ProxySelector.select(
            route: .proxy,
            access: access
        )
        let expected: ProxySelection = .http(
            endpoint: ProxyEndpoint(
                host: "127.0.0.1",
                port: 41001
            ),
            credentials: ProxyCredentials(
                user: "u",
                password: "p"
            )
        )
        XCTAssertEqual(selection, expected)
    }


    func testProxyRouteWithoutAccessFallsBackToBlackhole() {
        let selection: ProxySelection = ProxySelector.select(
            route: .proxy,
            access: nil
        )
        XCTAssertEqual(selection, blackholeSelection())
    }


    func testBlockedRouteUsesBlackholeEvenWithAccess() {
        let selection: ProxySelection = ProxySelector.select(
            route: .blocked,
            access: makeAccess()
        )
        XCTAssertEqual(selection, blackholeSelection())
    }


    func testBlackholeIsLoopbackDiscardPort() {
        XCTAssertEqual(ProxySelector.blackholeEndpoint.host, "127.0.0.1")
        XCTAssertEqual(ProxySelector.blackholeEndpoint.port, 9)
    }


    func testBasicAuthorizationEncodesUserAndPassword() {
        let value: String = ProxySelector.basicAuthorization(
            credentials: ProxyCredentials(
                user: "user",
                password: "pass"
            )
        )
        XCTAssertEqual(value, "Basic dXNlcjpwYXNz")
    }


    func testFirst407RetriesWithCredentials() {
        let value: String? = ProxySelector.proxyAuthorizationRetry(
            statusCode: 407,
            access: makeAccess(),
            alreadySentAuthorization: false
        )
        XCTAssertEqual(value, "Basic dTpw")
    }


    func testSecond407DoesNotRetryAgain() {
        let value: String? = ProxySelector.proxyAuthorizationRetry(
            statusCode: 407,
            access: makeAccess(),
            alreadySentAuthorization: true
        )
        XCTAssertNil(value)
    }


    func testNon407DoesNotRetry() {
        let value: String? = ProxySelector.proxyAuthorizationRetry(
            statusCode: 200,
            access: makeAccess(),
            alreadySentAuthorization: false
        )
        XCTAssertNil(value)
    }


    func testRetryWithoutRunningCoreGivesUp() {
        let value: String? = ProxySelector.proxyAuthorizationRetry(
            statusCode: 407,
            access: nil,
            alreadySentAuthorization: false
        )
        XCTAssertNil(value)
    }


    private func makeAccess() -> ProxyAccess {
        return ProxyAccess(
            endpoint: ProxyEndpoint(
                host: "127.0.0.1",
                port: 41001
            ),
            credentials: ProxyCredentials(
                user: "u",
                password: "p"
            )
        )
    }


    private func blackholeSelection() -> ProxySelection {
        return .http(
            endpoint: ProxySelector.blackholeEndpoint,
            credentials: nil
        )
    }


    private func expectedRoute(
        enabled: Bool,
        useForTransport: Bool,
        running: Bool
    ) -> ProxyRoute {
        if !enabled || !useForTransport {
            return .direct
        }
        return running ? .proxy : .blocked
    }
}
