import Foundation


/// Builds the URLSession connection proxy dictionary for a transport route.
///
/// The keys are the CFNetwork proxy keys (`kCFNetworkProxiesHTTPEnable` and its siblings). A route sets the HTTP and the
/// HTTPS entries, so the WebSocket (wss) and the plain HTTP requests both go through the HTTP inbound. The route carries
/// no credentials here: Basic credentials reach the socket through the native WebSocket challenge handling, not through
/// this dictionary.
public enum ImpulseProxyConnectionProxy {
    /// The CFNetwork key that enables the HTTP proxy.
    public static let httpEnableKey: String = "HTTPEnable"

    /// The CFNetwork key of the HTTP proxy host.
    public static let httpProxyKey: String = "HTTPProxy"

    /// The CFNetwork key of the HTTP proxy port.
    public static let httpPortKey: String = "HTTPPort"

    /// The CFNetwork key that enables the HTTPS proxy.
    public static let httpsEnableKey: String = "HTTPSEnable"

    /// The CFNetwork key of the HTTPS proxy host.
    public static let httpsProxyKey: String = "HTTPSProxy"

    /// The CFNetwork key of the HTTPS proxy port.
    public static let httpsPortKey: String = "HTTPSPort"


    /// The connection proxy dictionary for the route: nil for a nil route (a direct connection), otherwise the six keys
    /// `HTTPEnable`, `HTTPProxy`, `HTTPPort`, `HTTPSEnable`, `HTTPSProxy` and `HTTPSPort`, with the route host and port.
    public static func dictionary(for route: ImpulseProxyRoute?) -> [AnyHashable: Any]? {
        guard let route else {
            return nil
        }
        let enabled: Int = 1
        let result: [AnyHashable: Any] = [
            ImpulseProxyConnectionProxy.httpEnableKey: enabled,
            ImpulseProxyConnectionProxy.httpProxyKey: route.host,
            ImpulseProxyConnectionProxy.httpPortKey: route.port,
            ImpulseProxyConnectionProxy.httpsEnableKey: enabled,
            ImpulseProxyConnectionProxy.httpsProxyKey: route.host,
            ImpulseProxyConnectionProxy.httpsPortKey: route.port
        ]
        return result
    }
}
