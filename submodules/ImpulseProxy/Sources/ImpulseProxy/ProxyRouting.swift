/// Where the main transport sends its traffic.
public enum ProxyRoute: Equatable, Sendable {
    /// No proxy: the connection goes straight out.
    case direct
    /// Through the running core.
    case proxy
    /// The proxy is on but the core is not running: nothing may go out.
    case blocked
}


/// Kill switch: with the proxy setting on, traffic goes through the core or nowhere.
public enum ProxyRouting {
    /// Decides the route of the main transport.
    /// With the proxy off, or the transport toggle off, the traffic goes direct whatever the core is doing.
    public static func decide(
        enabled: Bool,
        useForTransport: Bool,
        running: Bool
    ) -> ProxyRoute {
        if !enabled || !useForTransport {
            return .direct
        }
        if running {
            return .proxy
        }
        return .blocked
    }


    /// Whether a call must be relayed through the tunnel.
    /// Deliberately independent of whether the core is running: with the core down a tunnelled call fails closed instead of going direct.
    public static func tunnelCalls(
        vlessFeature: Bool,
        enabled: Bool,
        useForCalls: Bool
    ) -> Bool {
        return vlessFeature && enabled && useForCalls
    }
}
