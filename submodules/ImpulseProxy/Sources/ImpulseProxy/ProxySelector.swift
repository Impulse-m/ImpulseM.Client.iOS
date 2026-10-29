import Foundation


/// Host and port of a proxy endpoint.
public struct ProxyEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int


    public init(
        host: String,
        port: Int
    ) {
        self.host = host
        self.port = port
    }
}


/// Basic credentials for the local core inbound.
public struct ProxyCredentials: Equatable, Sendable {
    public let user: String
    public let password: String


    public init(
        user: String,
        password: String
    ) {
        self.user = user
        self.password = password
    }
}


/// The loopback endpoint and credentials of a running core.
public struct ProxyAccess: Equatable, Sendable {
    public let endpoint: ProxyEndpoint
    public let credentials: ProxyCredentials


    public init(
        endpoint: ProxyEndpoint,
        credentials: ProxyCredentials
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
    }
}


/// The connection choice made for one request.
public enum ProxySelection: Equatable, Sendable {
    /// No proxy: the request goes straight out.
    case direct
    /// Through an HTTP proxy, with credentials when the endpoint requires them.
    case http(
        endpoint: ProxyEndpoint,
        credentials: ProxyCredentials?
    )
}


/// Chooses the connection for each request from the current route and core access.
public enum ProxySelector {
    /// The discard port on loopback. Connections fail at once, so a blocked route never falls back to direct.
    public static let blackholeEndpoint: ProxyEndpoint = ProxyEndpoint(
        host: "127.0.0.1",
        port: 9
    )


    /// DIRECT gives no proxy. PROXY gives the core HTTP endpoint when the core access is known, otherwise the blackhole. BLOCKED gives the blackhole.
    public static func select(
        route: ProxyRoute,
        access: ProxyAccess?
    ) -> ProxySelection {
        switch route {
        case .direct:
            return .direct

        case .proxy:
            if let access: ProxyAccess = access {
                return .http(
                    endpoint: access.endpoint,
                    credentials: access.credentials
                )
            }
            return .http(
                endpoint: blackholeEndpoint,
                credentials: nil
            )

        case .blocked:
            return .http(
                endpoint: blackholeEndpoint,
                credentials: nil
            )
        }
    }


    /// The Proxy-Authorization value to retry with after a 407, or nil when no retry applies.
    /// Only one retry is allowed: a request that already carried credentials is not retried again.
    public static func proxyAuthorizationRetry(
        statusCode: Int,
        access: ProxyAccess?,
        alreadySentAuthorization: Bool
    ) -> String? {
        if statusCode != 407 {
            return nil
        }
        if alreadySentAuthorization {
            return nil
        }
        guard let access: ProxyAccess = access else {
            return nil
        }
        return basicAuthorization(credentials: access.credentials)
    }


    /// Builds the Basic Proxy-Authorization value.
    public static func basicAuthorization(credentials: ProxyCredentials) -> String {
        let raw: String = credentials.user + ":" + credentials.password
        let encoded: String = Data(raw.utf8).base64EncodedString()
        return "Basic " + encoded
    }
}
