import Foundation
import SwiftCentrifuge


/// The settings of the SwiftCentrifuge clients of the transport (the update socket and the pool). The transport package
/// does not create the clients; whoever creates one applies these values.
public enum ImpulseSocketPolicy {
    /// The shortest delay before a reconnect, in seconds.
    public static let minReconnectDelaySeconds: Double = 1

    /// The longest delay between reconnects, in seconds.
    public static let maxReconnectDelaySeconds: Double = 30

    /// The allowance of the ping watchdog beyond the server's ping interval: a socket silent for longer than the interval
    /// plus this value is dropped and reconnected.
    public static let maxServerPingDelaySeconds: Double = 10


    /// The configuration of an update socket or pool client: reconnect backoff from 1 to 30 seconds, the ping watchdog,
    /// and the native WebSocket transport (the only one that accepts the proxy configuration). The client connects
    /// directly.
    public static func clientConfig(token: String) -> CentrifugeClientConfig {
        return ImpulseSocketPolicy.clientConfig(token: token, routeSource: nil)
    }


    /// The configuration of an update socket or pool client, as `clientConfig(token:)`, whose native WebSocket connects
    /// through the route of `routeSource` and answers the route's proxy Basic challenge with that route's credentials.
    /// The credentials are those of the route the current session was configured with, never those of a newer route.
    /// A nil source gives the direct configuration.
    public static func clientConfig(
        token: String,
        routeSource: ImpulseProxyRouteSource?
    ) -> CentrifugeClientConfig {
        let providers: ImpulseRouteProviders = ImpulseSocketPolicy.routeProviders(routeSource: routeSource)
        return CentrifugeClientConfig(
            minReconnectDelay: ImpulseSocketPolicy.minReconnectDelaySeconds,
            maxReconnectDelay: ImpulseSocketPolicy.maxReconnectDelaySeconds,
            maxServerPingDelay: ImpulseSocketPolicy.maxServerPingDelaySeconds,
            token: token,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: providers.configuration,
            proxyCredentialsProvider: providers.credentials
        )
    }


    /// The pair of providers of one native WebSocket client, bound to one route snapshot: the URLSession configuration
    /// provider records the route it builds a session with, and the credentials provider answers with that recorded route
    /// only. Both are nil when there is no source. Build the pair once per client config and pass both halves to it.
    public static func routeProviders(routeSource: ImpulseProxyRouteSource?) -> ImpulseRouteProviders {
        guard let routeSource else {
            return ImpulseRouteProviders(configuration: nil, credentials: nil)
        }
        let snapshot: ImpulseRouteSnapshot = ImpulseRouteSnapshot()
        let configurationProvider: URLSessionConfigurationProvider = {
            let route: ImpulseProxyRoute? = routeSource.currentRoute
            snapshot.store(route)
            let configuration: URLSessionConfiguration = URLSessionConfiguration.default
            let proxyDictionary: [AnyHashable: Any]? = ImpulseProxyConnectionProxy.dictionary(for: route)
            configuration.connectionProxyDictionary = proxyDictionary
            return configuration
        }
        let credentialsProvider: CentrifugeProxyCredentialsProvider = {
            guard let route: ImpulseProxyRoute = snapshot.storedRoute, let user: String = route.username, let password: String = route.password else {
                return nil
            }
            return CentrifugeProxyCredentials(user: user, password: password)
        }
        return ImpulseRouteProviders(configuration: configurationProvider, credentials: credentialsProvider)
    }


    /// The provider of the URLSession configuration of the native WebSocket. Nil when there is no source, which leaves the
    /// SDK default. Otherwise the SDK calls the provider once per session, when it creates the session, and the provider
    /// reads the route at that moment. Use `routeProviders(routeSource:)` to get the credentials bound to the same route.
    public static func urlSessionConfigurationProvider(
        routeSource: ImpulseProxyRouteSource?
    ) -> URLSessionConfigurationProvider? {
        return ImpulseSocketPolicy.routeProviders(routeSource: routeSource).configuration
    }
}


/// The providers of one native WebSocket client, made by `ImpulseSocketPolicy.routeProviders(routeSource:)`. Both halves
/// share one route snapshot.
public struct ImpulseRouteProviders {
    /// The URLSession configuration provider. Nil without a route source.
    public let configuration: URLSessionConfigurationProvider?

    /// The proxy credentials provider, bound to the route of the configuration provider's last call. Nil without a route
    /// source.
    public let credentials: CentrifugeProxyCredentialsProvider?
}


/// The route the last configuration of one client was built with. The SDK calls the configuration provider and the
/// credentials provider on its own queues, so the route is read and written under a lock.
internal final class ImpulseRouteSnapshot {
    private let lock: NSLock = NSLock()
    private var route: ImpulseProxyRoute?


    /// The route the last configuration was built with. Nil before any configuration was built, and when it was built
    /// without a route.
    internal var storedRoute: ImpulseProxyRoute? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return route
    }


    /// Records the route a configuration is built with, replacing the previous one.
    internal func store(_ newRoute: ImpulseProxyRoute?) {
        lock.lock()
        route = newRoute
        lock.unlock()
    }
}
