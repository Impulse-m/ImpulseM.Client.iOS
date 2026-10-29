import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class SocketPolicyNoopObservation: ImpulseProxyRouteObservation {
    func cancel() {
    }
}


private final class SocketPolicyRouteSource: ImpulseProxyRouteSource, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var route: ImpulseProxyRoute?


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
        return SocketPolicyNoopObservation()
    }


    func setRoute(_ newRoute: ImpulseProxyRoute?) {
        lock.lock()
        route = newRoute
        lock.unlock()
    }
}


final class ImpulseSocketPolicyTests: XCTestCase {
    func testPolicyValuesAreUnchanged() {
        XCTAssertEqual(ImpulseSocketPolicy.minReconnectDelaySeconds, 1)
        XCTAssertEqual(ImpulseSocketPolicy.maxReconnectDelaySeconds, 30)
        XCTAssertEqual(ImpulseSocketPolicy.maxServerPingDelaySeconds, 10)
    }


    func testClientConfigWithoutRouteKeepsTheSocketPolicyFields() {
        let config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token")

        XCTAssertEqual(config.minReconnectDelay, 1)
        XCTAssertEqual(config.maxReconnectDelay, 30)
        XCTAssertEqual(config.maxServerPingDelay, 10)
        XCTAssertEqual(config.token, "token")
        XCTAssertTrue(config.useNativeWebSocket)
        XCTAssertNil(config.urlSessionConfigurationProvider)
    }


    func testNilRouteSourceGivesTheSameFieldsAsTheTokenOnlyConfig() {
        let tokenOnly: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token")
        let withNilSource: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: nil)

        XCTAssertEqual(withNilSource.minReconnectDelay, tokenOnly.minReconnectDelay)
        XCTAssertEqual(withNilSource.maxReconnectDelay, tokenOnly.maxReconnectDelay)
        XCTAssertEqual(withNilSource.maxServerPingDelay, tokenOnly.maxServerPingDelay)
        XCTAssertEqual(withNilSource.token, tokenOnly.token)
        XCTAssertEqual(withNilSource.useNativeWebSocket, tokenOnly.useNativeWebSocket)
        XCTAssertNil(withNilSource.urlSessionConfigurationProvider)
    }


    func testNilSourceGivesNoProvider() {
        XCTAssertNil(ImpulseSocketPolicy.urlSessionConfigurationProvider(routeSource: nil))
    }


    func testSourceWithoutRouteGivesProviderWithoutProxy() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(route: nil)
        let provider: URLSessionConfigurationProvider? = ImpulseSocketPolicy.urlSessionConfigurationProvider(routeSource: source)
        let configuration: URLSessionConfiguration? = provider?()

        XCTAssertNotNil(provider)
        XCTAssertNil(configuration?.connectionProxyDictionary)
    }


    func testRouteChangeIsSeenByTheNextProviderCallWithTheSameProvider() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(route: nil)
        let config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        guard let provider: URLSessionConfigurationProvider = config.urlSessionConfigurationProvider else {
            XCTFail("The route config must carry a provider")
            return
        }
        let first: URLSessionConfiguration = provider()
        XCTAssertNil(first.connectionProxyDictionary)

        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        let second: URLSessionConfiguration = provider()
        let proxy: [AnyHashable: Any] = second.connectionProxyDictionary ?? [:]
        XCTAssertEqual(proxy["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxy["HTTPPort"] as? Int, 1080)
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, 1080)

        source.setRoute(nil)
        let third: URLSessionConfiguration = provider()
        XCTAssertNil(third.connectionProxyDictionary)
    }


    func testBlackholeRouteIsAppliedToTheProvider() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        )
        let config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        let configuration: URLSessionConfiguration? = config.urlSessionConfigurationProvider?()
        let proxy: [AnyHashable: Any] = configuration?.connectionProxyDictionary ?? [:]

        XCTAssertEqual(proxy["HTTPPort"] as? Int, 9)
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, 9)
    }


    func testNilSourceGivesNoCredentialsProvider() {
        XCTAssertNil(ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: nil))
    }


    func testRouteWithCredentialsGivesThem() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        )
        let provider: CentrifugeProxyCredentialsProvider? = ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: source)
        let credentials: CentrifugeProxyCredentials? = provider?()

        XCTAssertEqual(credentials?.user, "user")
        XCTAssertEqual(credentials?.password, "secret")
    }


    func testRouteWithoutCredentialsGivesNil() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil)
        )
        let provider: CentrifugeProxyCredentialsProvider? = ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: source)

        XCTAssertNotNil(provider)
        XCTAssertNil(provider?())
    }


    func testRouteWithUserOnlyGivesNil() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: nil)
        )
        let provider: CentrifugeProxyCredentialsProvider? = ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: source)

        XCTAssertNil(provider?())
    }


    func testNilCurrentRouteGivesNilCredentials() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(route: nil)
        let provider: CentrifugeProxyCredentialsProvider? = ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: source)

        XCTAssertNotNil(provider)
        XCTAssertNil(provider?())
    }


    func testCredentialsProviderReadsTheRouteAtCallTime() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(route: nil)
        let provider: CentrifugeProxyCredentialsProvider? = ImpulseSocketPolicy.proxyCredentialsProvider(routeSource: source)
        XCTAssertNil(provider?())

        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret"))
        let credentials: CentrifugeProxyCredentials? = provider?()

        XCTAssertEqual(credentials?.user, "user")
        XCTAssertEqual(credentials?.password, "secret")
    }


    func testClientConfigCarriesTheCredentialsProviderOfTheRoute() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        )
        let config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        guard let provider: CentrifugeProxyCredentialsProvider = config.proxyCredentialsProvider else {
            XCTFail("The route config must carry a credentials provider")
            return
        }
        let credentials: CentrifugeProxyCredentials? = provider()

        XCTAssertEqual(credentials?.user, "user")
        XCTAssertEqual(credentials?.password, "secret")
    }
}
