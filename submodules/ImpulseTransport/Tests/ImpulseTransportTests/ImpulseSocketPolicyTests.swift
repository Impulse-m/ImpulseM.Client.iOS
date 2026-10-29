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


    func testNilSourceGivesBothProvidersNil() {
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: nil)

        XCTAssertNil(providers.configuration)
        XCTAssertNil(providers.credentials)
    }


    func testCredentialsAreNilBeforeTheConfigurationIsBuilt() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)

        XCTAssertNotNil(providers.credentials)
        XCTAssertNil(providers.credentials?())
    }


    func testCredentialsAreThoseOfTheConfiguredRoute() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user-a", password: "secret-a")
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()
        let credentials: CentrifugeProxyCredentials? = providers.credentials?()

        XCTAssertEqual(credentials?.user, "user-a")
        XCTAssertEqual(credentials?.password, "secret-a")
    }


    /// The route changes between the session configuration and a proxy challenge (the core restarts with a new port and
    /// new credentials). The challenge gets the credentials of the route the session was configured with, and the next
    /// configuration gets the new ones.
    func testCredentialsStayOnTheConfiguredRouteAfterARouteChange() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user-a", password: "secret-a")
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()

        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 2080, username: "user-b", password: "secret-b"))
        let stale: CentrifugeProxyCredentials? = providers.credentials?()

        XCTAssertEqual(stale?.user, "user-a")
        XCTAssertEqual(stale?.password, "secret-a")

        _ = providers.configuration?()
        let fresh: CentrifugeProxyCredentials? = providers.credentials?()

        XCTAssertEqual(fresh?.user, "user-b")
        XCTAssertEqual(fresh?.password, "secret-b")
    }


    func testNilRouteAtConfigurationGivesNilCredentialsEvenAfterARouteAppears() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(route: nil)
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()

        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret"))

        XCTAssertNil(providers.credentials?())
    }


    func testRouteWithCredentialsGivesThemAfterTheConfiguration() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()
        let credentials: CentrifugeProxyCredentials? = providers.credentials?()

        XCTAssertEqual(credentials?.user, "user")
        XCTAssertEqual(credentials?.password, "secret")
    }


    func testRouteWithoutCredentialsGivesNil() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil)
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()

        XCTAssertNil(providers.credentials?())
    }


    func testRouteWithUserOnlyGivesNil() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: nil)
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()

        XCTAssertNil(providers.credentials?())
    }


    func testRouteWithPasswordOnlyGivesNil() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: "secret")
        )
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: source)
        _ = providers.configuration?()

        XCTAssertNil(providers.credentials?())
    }


    func testClientConfigPairStaysOnTheConfiguredRoute() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user-a", password: "secret-a")
        )
        let config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        guard let configuration: URLSessionConfigurationProvider = config.urlSessionConfigurationProvider else {
            XCTFail("The route config must carry a configuration provider")
            return
        }
        guard let credentialsProvider: CentrifugeProxyCredentialsProvider = config.proxyCredentialsProvider else {
            XCTFail("The route config must carry a credentials provider")
            return
        }
        XCTAssertNil(credentialsProvider())

        _ = configuration()
        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 2080, username: "user-b", password: "secret-b"))
        let stale: CentrifugeProxyCredentials? = credentialsProvider()

        XCTAssertEqual(stale?.user, "user-a")
        XCTAssertEqual(stale?.password, "secret-a")
    }


    func testEachClientConfigHasItsOwnSnapshot() {
        let source: SocketPolicyRouteSource = SocketPolicyRouteSource(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user-a", password: "secret-a")
        )
        let first: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        _ = first.urlSessionConfigurationProvider?()

        source.setRoute(ImpulseProxyRoute(host: "127.0.0.1", port: 2080, username: "user-b", password: "secret-b"))
        let second: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "token", routeSource: source)
        _ = second.urlSessionConfigurationProvider?()

        let firstCredentials: CentrifugeProxyCredentials? = first.proxyCredentialsProvider?()
        let secondCredentials: CentrifugeProxyCredentials? = second.proxyCredentialsProvider?()

        XCTAssertEqual(firstCredentials?.user, "user-a")
        XCTAssertEqual(secondCredentials?.user, "user-b")
    }
}
