import Foundation


/// The route the transport connects through: an HTTP proxy inbound with optional Basic credentials.
public struct ImpulseProxyRoute: Equatable, Sendable {
    /// The host name or address of the proxy inbound.
    public let host: String

    /// The port of the proxy inbound.
    public let port: Int

    /// The user name of the proxy, or nil when the inbound takes no credentials.
    public let username: String?

    /// The password of the proxy, or nil when the inbound takes no credentials.
    public let password: String?


    public init(
        host: String,
        port: Int,
        username: String?,
        password: String?
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}


/// A subscription to route changes. Cancelling it stops the deliveries; it is safe to cancel more than once.
public protocol ImpulseProxyRouteObservation: AnyObject {
    /// Stops the deliveries of the subscription. After this call the handler is never invoked again.
    func cancel()
}


/// The source of the route the transport uses for each new connection.
///
/// A nil `currentRoute` means a direct connection. A route that must block all traffic is a non-nil route, never nil,
/// so a source that cannot route fails closed instead of going direct.
///
/// `observe` delivers a route epoch: a number that grows with every change of the route. A handler receives each change
/// exactly once, and only until the returned observation is cancelled.
public protocol ImpulseProxyRouteSource: AnyObject, Sendable {
    /// The route for a connection opened now, or nil for a direct connection.
    var currentRoute: ImpulseProxyRoute? { get }

    /// Subscribes to route changes. The handler receives the new route epoch on each change.
    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation
}
