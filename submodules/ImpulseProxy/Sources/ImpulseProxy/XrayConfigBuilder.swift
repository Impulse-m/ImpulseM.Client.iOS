import Foundation


/// Loopback ports and per-start credentials of the running core.
public struct LocalInbounds: Equatable, Sendable {
    public let httpPort: Int
    public let socksPort: Int
    public let user: String
    public let password: String


    public init(
        httpPort: Int,
        socksPort: Int,
        user: String,
        password: String
    ) {
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.user = user
        self.password = password
    }
}


/// Failures of the Xray config builder.
public enum XrayConfigError: Error, Equatable, Sendable {
    /// A local inbound credential is empty.
    case emptyCredential(
        name: String
    )
    /// The stored outbound text is not a JSON object.
    case invalidOutbound
}


/// Builds the Xray run config (loopback HTTP and SOCKS inbounds with accounts, all traffic to the selected VLESS outbound)
/// and the ping config (the same outbound transformations, without inbounds or routing).
public enum XrayConfigBuilder {
    /// Tag of the proxy outbound. Routing sends every local inbound to it.
    public static let proxyTag: String = "proxy"
    /// Tag of the freedom outbound used by the classic fragment dialer.
    public static let fragmentTag: String = "fragment"

    private static let httpInboundTag: String = "http-in"
    private static let socksInboundTag: String = "socks-in"
    private static let loopbackAddress: String = "127.0.0.1"
    private static let offMode: String = "off"
    private static let classicMode: String = "classic"
    private static let cloudflareDnsMode: String = "cloudflare"
    private static let googleDnsMode: String = "google"
    private static let customDnsMode: String = "custom"
    private static let cloudflareDoh: String = "https://1.1.1.1/dns-query"
    private static let googleDoh: String = "https://8.8.8.8/dns-query"
    private static let ipv4Strategy: String = "UseIPv4"


    /// The fragmentation to apply: the mode is `classic` (freedom dialer) or `finalmask`.
    private struct FragmentSpec: Equatable {
        let mode: String
        let packets: String
        let length: String
        let interval: String
    }


    /// Returns the run config as compact JSON text with sorted keys.
    public static func build(
        server: ImpulseProxyState.Server,
        inbounds: LocalInbounds,
        advanced: ImpulseProxyState.Advanced? = nil
    ) throws -> String {
        try requireCredential(inbounds.user, name: "user")
        try requireCredential(inbounds.password, name: "password")
        let settings: ImpulseProxyState.Advanced = normalized(advanced)
        let log: [String: Any] = [
            "loglevel": "error",
            "access": "none"
        ]
        let inboundList: [[String: Any]] = [
            httpInbound(inbounds: inbounds),
            socksInbound(inbounds: inbounds)
        ]
        let rule: [String: Any] = [
            "type": "field",
            "inboundTag": [httpInboundTag, socksInboundTag],
            "outboundTag": proxyTag
        ]
        let routing: [String: Any] = [
            "domainStrategy": "AsIs",
            "rules": [rule]
        ]
        let outbounds: [[String: Any]] = try advancedOutbounds(server: server, advanced: settings)
        var config: [String: Any] = [
            "log": log,
            "inbounds": inboundList,
            "outbounds": outbounds,
            "routing": routing
        ]
        if let dns: [String: Any] = dnsObject(advanced: settings) {
            config["dns"] = dns
        }
        return try serialize(config)
    }


    /// Returns the ping config (outbounds and dns only) as compact JSON text with sorted keys.
    public static func pingConfig(
        server: ImpulseProxyState.Server,
        advanced: ImpulseProxyState.Advanced? = nil
    ) throws -> String {
        let settings: ImpulseProxyState.Advanced = normalized(advanced)
        let outbounds: [[String: Any]] = try advancedOutbounds(server: server, advanced: settings)
        var config: [String: Any] = [
            "outbounds": outbounds
        ]
        if let dns: [String: Any] = dnsObject(advanced: settings) {
            config["dns"] = dns
        }
        return try serialize(config)
    }


    /// Null or invalid settings are replaced with their defaults, so the builder never emits an invalid value.
    private static func normalized(
        _ advanced: ImpulseProxyState.Advanced?
    ) -> ImpulseProxyState.Advanced {
        var value: ImpulseProxyState.Advanced = advanced ?? ImpulseProxyState.Advanced()
        value.sanitize()
        return value
    }


    /// The proxy outbound with the advanced settings applied, plus the freedom dialer in classic mode.
    private static func advancedOutbounds(
        server: ImpulseProxyState.Server,
        advanced: ImpulseProxyState.Advanced
    ) throws -> [[String: Any]] {
        var proxy: [String: Any] = try taggedOutbound(server: server)
        let fragment: FragmentSpec? = effectiveFragment(server: server, advanced: advanced)
        let classic: Bool = fragment?.mode == classicMode
        let hasDns: Bool = effectiveDnsServer(advanced: advanced) != nil

        if !advanced.fingerprint.isEmpty {
            applyFingerprint(outbound: &proxy, fingerprint: advanced.fingerprint)
        }
        if advanced.muxEnabled && !usesVision(outbound: proxy) {
            let mux: [String: Any] = [
                "enabled": true,
                "concurrency": advanced.muxConcurrency
            ]
            proxy["mux"] = mux
        }

        var freedom: [String: Any]? = nil
        if let spec: FragmentSpec = fragment {
            if classic {
                setSockopt(outbound: &proxy, key: "dialerProxy", value: fragmentTag)
                freedom = makeFreedomOutbound(spec: spec)
            } else {
                setFinalMask(outbound: &proxy, spec: spec)
            }
        }

        // The dialing outbound carries the TCP options and the DNS strategy: the freedom dialer in classic mode.
        if var dialer: [String: Any] = freedom {
            applyDialerOptions(
                outbound: &dialer,
                advanced: advanced,
                hasDns: hasDns,
                isFreedom: true
            )
            freedom = dialer
        } else {
            applyDialerOptions(
                outbound: &proxy,
                advanced: advanced,
                hasDns: hasDns,
                isFreedom: false
            )
        }

        var outbounds: [[String: Any]] = [proxy]
        if let freedomValue: [String: Any] = freedom {
            outbounds.append(freedomValue)
        }
        return outbounds
    }


    private static func applyDialerOptions(
        outbound: inout [String: Any],
        advanced: ImpulseProxyState.Advanced,
        hasDns: Bool,
        isFreedom: Bool
    ) {
        if advanced.keepAliveIdle > 0 {
            setSockopt(outbound: &outbound, key: "tcpKeepAliveIdle", value: advanced.keepAliveIdle)
        }
        if advanced.keepAliveInterval > 0 {
            setSockopt(outbound: &outbound, key: "tcpKeepAliveInterval", value: advanced.keepAliveInterval)
        }
        if advanced.tcpFastOpen {
            setSockopt(outbound: &outbound, key: "tcpFastOpen", value: true)
        }
        if advanced.tcpMaxSeg > 0 {
            setSockopt(outbound: &outbound, key: "tcpMaxSeg", value: advanced.tcpMaxSeg)
        }
        if hasDns {
            if isFreedom {
                setFreedomDomainStrategy(outbound: &outbound)
            } else {
                setSockopt(outbound: &outbound, key: "domainStrategy", value: ipv4Strategy)
            }
        }
    }


    private static func dnsObject(
        advanced: ImpulseProxyState.Advanced
    ) -> [String: Any]? {
        guard let server: String = effectiveDnsServer(advanced: advanced) else {
            return nil
        }
        let dns: [String: Any] = [
            "servers": [server],
            "queryStrategy": ipv4Strategy
        ]
        return dns
    }


    private static func effectiveDnsServer(
        advanced: ImpulseProxyState.Advanced
    ) -> String? {
        switch advanced.dnsMode {
        case cloudflareDnsMode:
            return cloudflareDoh
        case googleDnsMode:
            return googleDoh
        case customDnsMode:
            return advanced.dnsCustom.isEmpty ? nil : advanced.dnsCustom
        default:
            return nil
        }
    }


    /// The fragmentation to apply, or nil for none. A global mode wins; otherwise a `fragment=` link parameter is honoured in classic mode.
    private static func effectiveFragment(
        server: ImpulseProxyState.Server,
        advanced: ImpulseProxyState.Advanced
    ) -> FragmentSpec? {
        if advanced.fragmentMode != offMode {
            return FragmentSpec(
                mode: advanced.fragmentMode,
                packets: advanced.fragmentPackets,
                length: advanced.fragmentLength,
                interval: advanced.fragmentInterval
            )
        }
        guard advanced.fragmentFromLink, let shareLink: String = server.shareLink else {
            return nil
        }
        guard let value: String = queryParameter(link: shareLink, name: "fragment") else {
            return nil
        }
        let parts: [String] = value.components(separatedBy: ",")
        if parts.count < 3 {
            return nil
        }
        let length: String = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let interval: String = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let packets: String = parts[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidFragment(length: length, interval: interval, packets: packets) else {
            return nil
        }
        return FragmentSpec(
            mode: classicMode,
            packets: packets,
            length: length,
            interval: interval
        )
    }


    /// Validates the link values with the same rules as the advanced settings.
    private static func isValidFragment(
        length: String,
        interval: String,
        packets: String
    ) -> Bool {
        var probe: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        probe.fragmentLength = length
        probe.fragmentInterval = interval
        probe.fragmentPackets = packets
        probe.sanitize()
        return probe.fragmentLength == length
            && probe.fragmentInterval == interval
            && probe.fragmentPackets == packets
    }


    /// The URL-decoded value of a query parameter in a share link, or nil when absent or malformed.
    private static func queryParameter(
        link: String,
        name: String
    ) -> String? {
        var withoutFragment: String = link
        if let hash: String.Index = link.firstIndex(of: "#") {
            withoutFragment = String(link[..<hash])
        }
        guard let question: String.Index = withoutFragment.firstIndex(of: "?") else {
            return nil
        }
        let query: String = String(withoutFragment[withoutFragment.index(after: question)...])
        for pair: Substring in query.split(separator: "&") {
            guard let equals: String.Index = pair.firstIndex(of: "=") else {
                continue
            }
            let key: String = String(pair[..<equals])
            if key.isEmpty || key != name {
                continue
            }
            let raw: String = String(pair[pair.index(after: equals)...])
            let spaced: String = raw.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding
        }
        return nil
    }


    private static func makeFreedomOutbound(
        spec: FragmentSpec
    ) -> [String: Any] {
        let fragment: [String: Any] = [
            "packets": spec.packets,
            "length": spec.length,
            "interval": spec.interval
        ]
        let settings: [String: Any] = ["fragment": fragment]
        let outbound: [String: Any] = [
            "tag": fragmentTag,
            "protocol": "freedom",
            "settings": settings
        ]
        return outbound
    }


    private static func setFinalMask(
        outbound: inout [String: Any],
        spec: FragmentSpec
    ) {
        let settings: [String: Any] = [
            "packets": spec.packets,
            "lengths": [spec.length],
            "delays": [spec.interval]
        ]
        let mask: [String: Any] = [
            "type": "fragment",
            "settings": settings
        ]
        let finalMask: [String: Any] = ["tcp": [mask]]
        mutateStream(outbound: &outbound) { (stream: inout [String: Any]) -> Void in
            stream["finalmask"] = finalMask
        }
    }


    /// Sets a key of `streamSettings.sockopt`, creating the containers on demand.
    private static func setSockopt(
        outbound: inout [String: Any],
        key: String,
        value: Any
    ) {
        mutateStream(outbound: &outbound) { (stream: inout [String: Any]) -> Void in
            var sockopt: [String: Any] = (stream["sockopt"] as? [String: Any]) ?? [:]
            sockopt[key] = value
            stream["sockopt"] = sockopt
        }
    }


    private static func setFreedomDomainStrategy(
        outbound: inout [String: Any]
    ) {
        var settings: [String: Any] = (outbound["settings"] as? [String: Any]) ?? [:]
        settings["domainStrategy"] = ipv4Strategy
        outbound["settings"] = settings
    }


    private static func mutateStream(
        outbound: inout [String: Any],
        _ body: (inout [String: Any]) -> Void
    ) {
        var stream: [String: Any] = (outbound["streamSettings"] as? [String: Any]) ?? [:]
        body(&stream)
        outbound["streamSettings"] = stream
    }


    /// Sets the fingerprint on tlsSettings and realitySettings, but only where those settings already exist.
    private static func applyFingerprint(
        outbound: inout [String: Any],
        fingerprint: String
    ) {
        guard var stream: [String: Any] = outbound["streamSettings"] as? [String: Any] else {
            return
        }
        setFingerprintIfPresent(stream: &stream, key: "tlsSettings", fingerprint: fingerprint)
        setFingerprintIfPresent(stream: &stream, key: "realitySettings", fingerprint: fingerprint)
        outbound["streamSettings"] = stream
    }


    private static func setFingerprintIfPresent(
        stream: inout [String: Any],
        key: String,
        fingerprint: String
    ) {
        guard var settings: [String: Any] = stream[key] as? [String: Any] else {
            return
        }
        settings["fingerprint"] = fingerprint
        stream[key] = settings
    }


    /// Vision flow is incompatible with mux. Checks settings.flow and the flow of every vnext user.
    private static func usesVision(
        outbound: [String: Any]
    ) -> Bool {
        guard let settings: [String: Any] = outbound["settings"] as? [String: Any] else {
            return false
        }
        if isVision(settings["flow"]) {
            return true
        }
        guard let vnext: [Any] = settings["vnext"] as? [Any] else {
            return false
        }
        for endpointValue: Any in vnext {
            guard let endpoint: [String: Any] = endpointValue as? [String: Any] else {
                continue
            }
            guard let users: [Any] = endpoint["users"] as? [Any] else {
                continue
            }
            for userValue: Any in users {
                if let user: [String: Any] = userValue as? [String: Any], isVision(user["flow"]) {
                    return true
                }
            }
        }
        return false
    }


    private static func isVision(
        _ flow: Any?
    ) -> Bool {
        guard let text: String = flow as? String else {
            return false
        }
        return text.hasPrefix("xtls-rprx-vision")
    }


    private static func requireCredential(
        _ value: String,
        name: String
    ) throws {
        if value.isEmpty {
            throw XrayConfigError.emptyCredential(name: name)
        }
    }


    /// Parses the stored outbound text and tags it as the proxy outbound. The stored server is never changed.
    private static func taggedOutbound(
        server: ImpulseProxyState.Server
    ) throws -> [String: Any] {
        guard let data: Data = server.outboundJson.data(using: .utf8) else {
            throw XrayConfigError.invalidOutbound
        }
        guard let parsed: Any = try? JSONSerialization.jsonObject(with: data) else {
            throw XrayConfigError.invalidOutbound
        }
        guard var outbound: [String: Any] = parsed as? [String: Any] else {
            throw XrayConfigError.invalidOutbound
        }
        outbound["tag"] = proxyTag
        return outbound
    }


    private static func account(
        inbounds: LocalInbounds
    ) -> [String: Any] {
        let account: [String: Any] = [
            "user": inbounds.user,
            "pass": inbounds.password
        ]
        return account
    }


    private static func httpInbound(
        inbounds: LocalInbounds
    ) -> [String: Any] {
        let accounts: [[String: Any]] = [account(inbounds: inbounds)]
        let settings: [String: Any] = [
            "accounts": accounts,
            "allowTransparent": false
        ]
        let inbound: [String: Any] = [
            "tag": httpInboundTag,
            "listen": loopbackAddress,
            "port": inbounds.httpPort,
            "protocol": "http",
            "settings": settings
        ]
        return inbound
    }


    private static func socksInbound(
        inbounds: LocalInbounds
    ) -> [String: Any] {
        let accounts: [[String: Any]] = [account(inbounds: inbounds)]
        let settings: [String: Any] = [
            "auth": "password",
            "accounts": accounts,
            "udp": true,
            "ip": loopbackAddress
        ]
        let inbound: [String: Any] = [
            "tag": socksInboundTag,
            "listen": loopbackAddress,
            "port": inbounds.socksPort,
            "protocol": "socks",
            "settings": settings
        ]
        return inbound
    }


    private static func serialize(
        _ object: [String: Any]
    ) throws -> String {
        let data: Data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
