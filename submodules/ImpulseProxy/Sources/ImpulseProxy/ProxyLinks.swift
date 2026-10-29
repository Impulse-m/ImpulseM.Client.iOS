import Foundation


/// Receives the text of share links and returns one Xray outbound JSON text per link, as libXray does.
public protocol ShareLinkConverter: Sendable {
    func convertShareLinks(
        text: String
    ) throws -> [String]
}


extension LibXrayClient: ShareLinkConverter {
}


/// What the user pasted into the add field.
public enum ProxyInputKind: Equatable, Sendable {
    /// One or more `vless://` share lines.
    case links
    /// A single `http(s)://` subscription URL.
    case subscription
    /// Neither.
    case unknown
}


/// Outbounds kept from one conversion, and how many outbounds were not usable VLESS servers.
public struct ProxyOutboundFilterResult: Equatable, Sendable {
    public let servers: [ImpulseProxyState.Server]
    public let skipped: Int


    public init(
        servers: [ImpulseProxyState.Server],
        skipped: Int
    ) {
        self.servers = servers
        self.skipped = skipped
    }
}


/// Keeps the VLESS outbounds of a conversion result and turns each one into a selectable server.
public enum ProxyOutboundFilter {
    private static let vlessProtocol: String = "vless"
    private static let defaultNetwork: String = "tcp"
    private static let defaultSecurity: String = "none"


    public static func filter(
        outbounds: [String]
    ) -> ProxyOutboundFilterResult {
        var servers: [ImpulseProxyState.Server] = []
        var skipped: Int = 0
        for outboundJson: String in outbounds {
            if let server: ImpulseProxyState.Server = makeServer(outboundJson: outboundJson) {
                servers.append(server)
            } else {
                skipped += 1
            }
        }
        return ProxyOutboundFilterResult(servers: servers, skipped: skipped)
    }


    /// Returns nil for anything that is not a VLESS outbound with a usable address and port.
    public static func makeServer(
        outboundJson: String
    ) -> ImpulseProxyState.Server? {
        guard let data: Data = outboundJson.data(using: .utf8) else {
            return nil
        }
        guard let outbound: [String: Any] = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard let protocolName: String = outbound["protocol"] as? String, protocolName == vlessProtocol else {
            return nil
        }
        let settings: [String: Any] = (outbound["settings"] as? [String: Any]) ?? [:]
        var endpoint: [String: Any] = settings
        if let vnextValue: Any = settings["vnext"] {
            guard let vnext: [Any] = vnextValue as? [Any] else {
                return nil
            }
            if let first: Any = vnext.first {
                guard let firstEndpoint: [String: Any] = first as? [String: Any] else {
                    return nil
                }
                endpoint = firstEndpoint
            }
        }
        let host: String = (endpoint["address"] as? String) ?? ""
        let port: Int = (endpoint["port"] as? Int) ?? 0
        if host.isEmpty || port <= 0 {
            return nil
        }
        let stream: [String: Any] = (outbound["streamSettings"] as? [String: Any]) ?? [:]
        let network: String = (stream["network"] as? String) ?? defaultNetwork
        let security: String = (stream["security"] as? String) ?? defaultSecurity
        let tag: String = ((outbound["tag"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ImpulseProxyState.Server(
            id: ImpulseProxyState.Server.makeId(outboundJson: outboundJson),
            name: tag.isEmpty ? host : tag,
            host: host,
            port: port,
            network: network,
            security: security,
            outboundJson: outboundJson,
            shareLink: nil
        )
    }
}


/// Detection of pasted input and conversion of manually entered share links.
public enum ProxyLinks {
    private static let vlessPrefix: String = "vless://"
    private static let httpsPrefix: String = "https://"
    private static let httpPrefix: String = "http://"


    /// Classifies pasted text: a bare http(s) URL without whitespace is a subscription; any line that starts with `vless://` makes it links.
    public static func detectInputKind(
        text: String
    ) -> ProxyInputKind {
        let value: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return .unknown
        }
        let lower: String = value.lowercased()
        let isHttpURL: Bool = lower.hasPrefix(httpsPrefix) || lower.hasPrefix(httpPrefix)
        if isHttpURL && !containsWhitespace(value) {
            return .subscription
        }
        for line: Substring in splitLines(value) {
            if isVlessLine(String(line)) {
                return .links
            }
        }
        return .unknown
    }


    /// Converts each `vless://` line on its own. Other lines are ignored, and a line that libXray rejects is dropped.
    /// Every kept server remembers the trimmed share line it came from.
    public static func parseLinks(
        text: String,
        converter: ShareLinkConverter
    ) -> [ImpulseProxyState.Server] {
        var servers: [ImpulseProxyState.Server] = []
        for rawLine: Substring in splitLines(text) {
            let line: String = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !isVlessLine(line) {
                continue
            }
            let outbounds: [String]
            do {
                outbounds = try converter.convertShareLinks(text: line)
            } catch {
                continue
            }
            for server: ImpulseProxyState.Server in ProxyOutboundFilter.filter(outbounds: outbounds).servers {
                var linked: ImpulseProxyState.Server = server
                linked.shareLink = line
                servers.append(linked)
            }
        }
        return servers
    }


    private static func isVlessLine(
        _ line: String
    ) -> Bool {
        let trimmed: String = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix(vlessPrefix)
    }


    private static func splitLines(
        _ text: String
    ) -> [Substring] {
        return text.split(whereSeparator: { (character: Character) -> Bool in
            return character.isNewline
        })
    }


    private static func containsWhitespace(
        _ value: String
    ) -> Bool {
        return value.contains(where: { (character: Character) -> Bool in
            return character.isWhitespace
        })
    }
}
