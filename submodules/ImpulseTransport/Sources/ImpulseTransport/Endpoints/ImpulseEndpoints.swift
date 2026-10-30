import Foundation

public enum ImpulseEndpointsError: Error, Equatable {
    case invalidBaseUrl(String)
}

public struct ImpulseDcOption: Equatable, Sendable {
    public let id: Int32
    public let ipAddress: String
    public let port: Int
    public let ipv6: Bool
    public let mediaOnly: Bool

    public init(
        id: Int32,
        ipAddress: String,
        port: Int,
        ipv6: Bool,
        mediaOnly: Bool
    ) {
        self.id = id
        self.ipAddress = ipAddress
        self.port = port
        self.ipv6 = ipv6
        self.mediaOnly = mediaOnly
    }
}

public struct ImpulseEndpoints: Equatable, Sendable {
    public let rpcBaseUrl: URL

    private static let realtimePath: String = "/connection/websocket?cf_ws_frame_ping_pong=true"
    private static let poolPath: String = "/pool/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
    private static let mediaPath: String = "/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"

    private let websocketBase: String

    public init(baseUrl: String) throws {
        guard let components: URLComponents = URLComponents(string: baseUrl) else {
            throw ImpulseEndpointsError.invalidBaseUrl(baseUrl)
        }

        guard let scheme: String = components.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ImpulseEndpointsError.invalidBaseUrl(baseUrl)
        }

        guard let host: String = components.host, !host.isEmpty else {
            throw ImpulseEndpointsError.invalidBaseUrl(baseUrl)
        }

        guard let url: URL = URL(string: baseUrl) else {
            throw ImpulseEndpointsError.invalidBaseUrl(baseUrl)
        }

        let isHttps: Bool = scheme == "https"
        let defaultPort: Int = isHttps ? 443 : 80
        let port: Int = components.port ?? defaultPort

        var authority: String = host
        if port != defaultPort {
            authority += ":\(port)"
        }

        self.rpcBaseUrl = url
        self.websocketBase = (isHttps ? "wss" : "ws") + "://" + authority
    }

    public func realtimeUrl() -> String {
        return websocketBase + ImpulseEndpoints.realtimePath
    }

    public func poolUrl() -> String {
        return websocketBase + ImpulseEndpoints.poolPath
    }

    public static func mediaUrl(
        dcOptions: [ImpulseDcOption],
        thisDc: Int32
    ) -> String? {
        for option: ImpulseDcOption in dcOptions {
            guard option.mediaOnly, option.id == thisDc else {
                continue
            }

            let host: String = option.ipv6 ? "[\(option.ipAddress)]" : option.ipAddress
            return "wss://\(host):\(option.port)" + mediaPath
        }

        return nil
    }
}
