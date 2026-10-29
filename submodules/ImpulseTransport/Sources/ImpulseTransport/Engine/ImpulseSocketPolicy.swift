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
    /// through the route of `routeSource`. A nil source gives the direct configuration.
    public static func clientConfig(
        token: String,
        routeSource: ImpulseProxyRouteSource?
    ) -> CentrifugeClientConfig {
        return CentrifugeClientConfig(
            minReconnectDelay: ImpulseSocketPolicy.minReconnectDelaySeconds,
            maxReconnectDelay: ImpulseSocketPolicy.maxReconnectDelaySeconds,
            maxServerPingDelay: ImpulseSocketPolicy.maxServerPingDelaySeconds,
            token: token,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: ImpulseSocketPolicy.urlSessionConfigurationProvider(routeSource: routeSource)
        )
    }


    /// The provider of the URLSession configuration of the native WebSocket. Nil when there is no source, which leaves the
    /// SDK default. Otherwise the provider is called by the SDK on every connect and reads the route at that moment, so a
    /// route change applies to the next connection without a new client.
    public static func urlSessionConfigurationProvider(
        routeSource: ImpulseProxyRouteSource?
    ) -> URLSessionConfigurationProvider? {
        guard let routeSource else {
            return nil
        }
        let provider: URLSessionConfigurationProvider = {
            let configuration: URLSessionConfiguration = URLSessionConfiguration.default
            let proxyDictionary: [AnyHashable: Any]? = ImpulseProxyConnectionProxy.dictionary(for: routeSource.currentRoute)
            configuration.connectionProxyDictionary = proxyDictionary
            return configuration
        }
        return provider
    }
}
