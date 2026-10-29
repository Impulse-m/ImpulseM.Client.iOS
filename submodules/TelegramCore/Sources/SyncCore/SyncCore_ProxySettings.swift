import Foundation
import Postbox

public enum ProxyServerConnection: Equatable, Hashable, Codable {
    case socks5(username: String?, password: String?)
    case mtp(secret: Data)
    case web(secret: Data, path: String)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        switch try container.decode(Int32.self, forKey: "_t") {
            case 0:
                self = .socks5(username: try container.decodeIfPresent(String.self, forKey: "username"), password: try container.decodeIfPresent(String.self, forKey: "password"))
            case 1:
                self = .mtp(secret: try container.decode(Data.self, forKey: "secret"))
            case 2:
                self = .web(secret: try container.decode(Data.self, forKey: "secret"), path: "")
            case 3:
                self = .web(secret: try container.decode(Data.self, forKey: "secret"), path: try container.decode(String.self, forKey: "path"))
            default:
                self = .socks5(username: nil, password: nil)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        switch self {
            case let .socks5(username, password):
                try container.encode(0 as Int32, forKey: "_t")
                try container.encodeIfPresent(username, forKey: "username")
                try container.encodeIfPresent(password, forKey: "password")
            case let .mtp(secret):
                try container.encode(1 as Int32, forKey: "_t")
                try container.encode(secret, forKey: "secret")
            case let .web(secret, path):
                if path.isEmpty {
                    try container.encode(2 as Int32, forKey: "_t")
                    try container.encode(secret, forKey: "secret")
                } else {
                    try container.encode(3 as Int32, forKey: "_t")
                    try container.encode(secret, forKey: "secret")
                    try container.encode(path, forKey: "path")
                }
        }
    }
}

public struct ProxyServerSettings: Codable, Equatable, Hashable {
    public let host: String
    public let port: Int32
    public let connection: ProxyServerConnection
    
    public init(host: String, port: Int32, connection: ProxyServerConnection) {
        self.host = host
        if case .web = connection {
            self.port = 443
        } else {
            self.port = port
        }
        self.connection = connection
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        let host = (try? container.decode(String.self, forKey: "host")) ?? ""
        let port = (try? container.decode(Int32.self, forKey: "port")) ?? 0
        let connection: ProxyServerConnection
        if let username = try container.decodeIfPresent(String.self, forKey: "username") {
            connection = .socks5(username: username, password: try container.decodeIfPresent(String.self, forKey: "password"))
        } else {
            connection = (try? container.decodeIfPresent(ProxyServerConnection.self, forKey: "connection")) ?? ProxyServerConnection.socks5(username: nil, password: nil)
        }
        self.init(host: host, port: port, connection: connection)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.host, forKey: "host")
        try container.encode(self.port, forKey: "port")
        try container.encode(self.connection, forKey: "connection")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.host)
        hasher.combine(self.port)
        hasher.combine(self.connection)
    }
}

/// The ImpulseM proxy settings record, stored under the proxy settings shared-data key.
/// Stored JSON carries a `v` key; a record without it (every legacy `ProxySettings` record) does not decode as this type.
public struct ImpulseProxyState: Equatable, Codable {
    /// The value of the `v` key this model writes and accepts.
    public static let currentVersion: Int32 = 1

    public var enabled: Bool
    /// Main traffic goes through the Xray HTTP inbound.
    public private(set) var useForTransport: Bool
    /// LiveKit calls go through the Xray SOCKS5 inbound.
    public private(set) var useForCalls: Bool
    public var selectedId: String?
    public var manual: [ImpulseProxyState.Server]
    public var subscriptions: [ImpulseProxyState.Subscription]
    public var advanced: ImpulseProxyState.Advanced

    public struct Server: Equatable, Codable {
        public var id: String
        public var name: String
        public var host: String
        public var port: Int32
        public var network: String
        public var security: String
        public var outboundJson: String
        /// The original share line of a manually added server; nil for subscription servers.
        public var shareLink: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case host
            case port
            case network
            case security
            case outboundJson = "outbound"
            case shareLink
        }

        public init(
            id: String,
            name: String,
            host: String,
            port: Int32,
            network: String,
            security: String,
            outboundJson: String,
            shareLink: String? = nil
        ) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.network = network
            self.security = security
            self.outboundJson = outboundJson
            self.shareLink = shareLink
        }
    }

    public struct SubscriptionMeta: Equatable, Codable {
        /// Panel headers of a subscription. Defaults: no title, -1 for every traffic value, 24 hours.
        public var title: String?
        public var upload: Int64
        public var download: Int64
        public var total: Int64
        public var expire: Int64
        public var updateIntervalHours: Int32

        private enum CodingKeys: String, CodingKey {
            case title
            case upload
            case download
            case total
            case expire
            case updateIntervalHours = "interval"
        }

        public init(
            title: String? = nil,
            upload: Int64 = -1,
            download: Int64 = -1,
            total: Int64 = -1,
            expire: Int64 = -1,
            updateIntervalHours: Int32 = 24
        ) {
            self.title = title
            self.upload = upload
            self.download = download
            self.total = total
            self.expire = expire
            self.updateIntervalHours = updateIntervalHours
        }

        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<SubscriptionMeta.CodingKeys> = try decoder.container(keyedBy: SubscriptionMeta.CodingKeys.self)
            let titleValue: String? = try? container.decodeIfPresent(String.self, forKey: .title)
            let uploadValue: Int64 = (try? container.decodeIfPresent(Int64.self, forKey: .upload)) ?? -1
            let downloadValue: Int64 = (try? container.decodeIfPresent(Int64.self, forKey: .download)) ?? -1
            let totalValue: Int64 = (try? container.decodeIfPresent(Int64.self, forKey: .total)) ?? -1
            let expireValue: Int64 = (try? container.decodeIfPresent(Int64.self, forKey: .expire)) ?? -1
            let intervalValue: Int32 = (try? container.decodeIfPresent(Int32.self, forKey: .updateIntervalHours)) ?? 24
            self.init(
                title: titleValue,
                upload: uploadValue,
                download: downloadValue,
                total: totalValue,
                expire: expireValue,
                updateIntervalHours: intervalValue
            )
        }
    }

    public struct Subscription: Equatable, Codable {
        public var id: String
        public var url: String
        public var meta: ImpulseProxyState.SubscriptionMeta
        public var updatedAt: Int64
        public var lastError: String?
        public var skipped: Int32
        public var servers: [ImpulseProxyState.Server]

        private enum CodingKeys: String, CodingKey {
            case id
            case url
            case meta
            case updatedAt
            case lastError
            case skipped
            case servers
        }

        public init(
            id: String,
            url: String,
            meta: ImpulseProxyState.SubscriptionMeta = ImpulseProxyState.SubscriptionMeta(),
            updatedAt: Int64 = 0,
            lastError: String? = nil,
            skipped: Int32 = 0,
            servers: [ImpulseProxyState.Server] = []
        ) {
            self.id = id
            self.url = url
            self.meta = meta
            self.updatedAt = updatedAt
            self.lastError = lastError
            self.skipped = skipped
            self.servers = servers
        }

        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<Subscription.CodingKeys> = try decoder.container(keyedBy: Subscription.CodingKeys.self)
            let idValue: String = try container.decode(String.self, forKey: .id)
            let urlValue: String = try container.decode(String.self, forKey: .url)
            let metaValue: ImpulseProxyState.SubscriptionMeta = (try? container.decodeIfPresent(ImpulseProxyState.SubscriptionMeta.self, forKey: .meta)) ?? ImpulseProxyState.SubscriptionMeta()
            let updatedValue: Int64 = (try? container.decodeIfPresent(Int64.self, forKey: .updatedAt)) ?? 0
            let errorValue: String? = try? container.decodeIfPresent(String.self, forKey: .lastError)
            let skippedValue: Int32 = (try? container.decodeIfPresent(Int32.self, forKey: .skipped)) ?? 0
            let serversValue: [ImpulseProxyState.Server] = (try? container.decodeIfPresent([ImpulseProxyState.Server].self, forKey: .servers)) ?? []
            self.init(
                id: idValue,
                url: urlValue,
                meta: metaValue,
                updatedAt: updatedValue,
                lastError: errorValue,
                skipped: skippedValue,
                servers: serversValue
            )
        }
    }

    /// Advanced proxy options. Every decoded value is sanitized to a valid one.
    public struct Advanced: Equatable, Codable {
        public var fragmentMode: String = "off"
        public var fragmentPackets: String = "tlshello"
        public var fragmentLength: String = "100-200"
        public var fragmentInterval: String = "10-20"
        public var fragmentFromLink: Bool = true
        public var fingerprint: String = ""
        public var muxEnabled: Bool = false
        public var muxConcurrency: Int32 = 8
        public var keepAliveIdle: Int32 = 0
        public var keepAliveInterval: Int32 = 0
        public var tcpFastOpen: Bool = false
        public var tcpMaxSeg: Int32 = 0
        public var dnsMode: String = "system"
        public var dnsCustom: String = ""
        public var pingMode: String = "batch"
        public var pingPauseMillis: Int32 = 0
        public var pingTimeoutSeconds: Int32 = 5
        public var pingUrl: String = "https://www.gstatic.com/generate_204"
        public var pingSkipWhileConnected: Bool = true

        private static let fragmentModes: [String] = ["off", "classic", "finalmask"]
        private static let fingerprints: [String] = ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"]
        private static let dnsModes: [String] = ["system", "cloudflare", "google", "custom"]
        private static let pingModes: [String] = ["batch", "sequential"]

        private enum CodingKeys: String, CodingKey {
            case fragmentMode
            case fragmentPackets
            case fragmentLength
            case fragmentInterval
            case fragmentFromLink
            case fingerprint
            case muxEnabled
            case muxConcurrency
            case keepAliveIdle
            case keepAliveInterval
            case tcpFastOpen
            case tcpMaxSeg
            case dnsMode
            case dnsCustom
            case pingMode
            case pingPauseMillis
            case pingTimeoutSeconds
            case pingUrl
            case pingSkipWhileConnected
        }

        public init() {
        }

        public init(from decoder: Decoder) throws {
            self.init()
            let container: KeyedDecodingContainer<Advanced.CodingKeys> = try decoder.container(keyedBy: Advanced.CodingKeys.self)
            self.fragmentMode = (try? container.decodeIfPresent(String.self, forKey: .fragmentMode)) ?? self.fragmentMode
            self.fragmentPackets = (try? container.decodeIfPresent(String.self, forKey: .fragmentPackets)) ?? self.fragmentPackets
            self.fragmentLength = (try? container.decodeIfPresent(String.self, forKey: .fragmentLength)) ?? self.fragmentLength
            self.fragmentInterval = (try? container.decodeIfPresent(String.self, forKey: .fragmentInterval)) ?? self.fragmentInterval
            self.fragmentFromLink = (try? container.decodeIfPresent(Bool.self, forKey: .fragmentFromLink)) ?? self.fragmentFromLink
            self.fingerprint = (try? container.decodeIfPresent(String.self, forKey: .fingerprint)) ?? self.fingerprint
            self.muxEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .muxEnabled)) ?? self.muxEnabled
            self.muxConcurrency = (try? container.decodeIfPresent(Int32.self, forKey: .muxConcurrency)) ?? self.muxConcurrency
            self.keepAliveIdle = (try? container.decodeIfPresent(Int32.self, forKey: .keepAliveIdle)) ?? self.keepAliveIdle
            self.keepAliveInterval = (try? container.decodeIfPresent(Int32.self, forKey: .keepAliveInterval)) ?? self.keepAliveInterval
            self.tcpFastOpen = (try? container.decodeIfPresent(Bool.self, forKey: .tcpFastOpen)) ?? self.tcpFastOpen
            self.tcpMaxSeg = (try? container.decodeIfPresent(Int32.self, forKey: .tcpMaxSeg)) ?? self.tcpMaxSeg
            self.dnsMode = (try? container.decodeIfPresent(String.self, forKey: .dnsMode)) ?? self.dnsMode
            self.dnsCustom = (try? container.decodeIfPresent(String.self, forKey: .dnsCustom)) ?? self.dnsCustom
            self.pingMode = (try? container.decodeIfPresent(String.self, forKey: .pingMode)) ?? self.pingMode
            self.pingPauseMillis = (try? container.decodeIfPresent(Int32.self, forKey: .pingPauseMillis)) ?? self.pingPauseMillis
            self.pingTimeoutSeconds = (try? container.decodeIfPresent(Int32.self, forKey: .pingTimeoutSeconds)) ?? self.pingTimeoutSeconds
            self.pingUrl = (try? container.decodeIfPresent(String.self, forKey: .pingUrl)) ?? self.pingUrl
            self.pingSkipWhileConnected = (try? container.decodeIfPresent(Bool.self, forKey: .pingSkipWhileConnected)) ?? self.pingSkipWhileConnected
            self.sanitize()
        }

        /// Replaces every invalid value with its default.
        public mutating func sanitize() {
            if !Advanced.fragmentModes.contains(self.fragmentMode) {
                self.fragmentMode = "off"
            }
            if !Advanced.isPackets(self.fragmentPackets) {
                self.fragmentPackets = "tlshello"
            }
            if !Advanced.isRange(self.fragmentLength) {
                self.fragmentLength = "100-200"
            }
            if !Advanced.isRange(self.fragmentInterval) {
                self.fragmentInterval = "10-20"
            }
            if !self.fingerprint.isEmpty && !Advanced.fingerprints.contains(self.fingerprint) {
                self.fingerprint = ""
            }
            if self.muxConcurrency < 1 || self.muxConcurrency > 128 {
                self.muxConcurrency = 8
            }
            if self.keepAliveIdle < 0 || self.keepAliveIdle > 86400 {
                self.keepAliveIdle = 0
            }
            if self.keepAliveInterval < 0 || self.keepAliveInterval > 86400 {
                self.keepAliveInterval = 0
            }
            if self.tcpMaxSeg != 0 && (self.tcpMaxSeg < 64 || self.tcpMaxSeg > 1460) {
                self.tcpMaxSeg = 0
            }
            if !Advanced.dnsModes.contains(self.dnsMode) {
                self.dnsMode = "system"
            }
            if !self.dnsCustom.isEmpty && !Advanced.isDnsServer(self.dnsCustom) {
                self.dnsCustom = ""
            }
            if self.dnsMode == "custom" && self.dnsCustom.isEmpty {
                self.dnsMode = "system"
            }
            if !Advanced.pingModes.contains(self.pingMode) {
                self.pingMode = "batch"
            }
            if self.pingPauseMillis < 0 || self.pingPauseMillis > 10000 {
                self.pingPauseMillis = 0
            }
            if self.pingTimeoutSeconds < 1 || self.pingTimeoutSeconds > 30 {
                self.pingTimeoutSeconds = 5
            }
            if !self.pingUrl.hasPrefix("https://") || self.pingUrl.count <= "https://".count {
                self.pingUrl = "https://www.gstatic.com/generate_204"
            }
        }

        /// Accepts "N" or "N-M" with 0 <= N <= M <= 65535.
        private static func isRange(_ value: String) -> Bool {
            let parts: [Substring] = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 1 {
                return parseBounded(String(parts[0])) >= 0
            }
            let low: Int = parseBounded(String(parts[0]))
            let high: Int = parseBounded(String(parts[1]))
            return low >= 0 && high >= 0 && low <= high
        }

        /// Accepts "tlshello" or a range.
        private static func isPackets(_ value: String) -> Bool {
            return value == "tlshello" || isRange(value)
        }

        /// Accepts an https:// URL or an IPv4 address.
        private static func isDnsServer(_ value: String) -> Bool {
            if value.hasPrefix("https://") {
                return value.count > "https://".count && !value.contains(" ")
            }
            let parts: [Substring] = value.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count != 4 {
                return false
            }
            for part: Substring in parts {
                if part.isEmpty || part.count > 3 || !isDigits(String(part)) {
                    return false
                }
                guard let number: Int = Int(part), number <= 255 else {
                    return false
                }
            }
            return true
        }

        /// Parses digits only into 0...65535; -1 when invalid.
        private static func parseBounded(_ text: String) -> Int {
            if text.isEmpty || text.count > 5 || !isDigits(text) {
                return -1
            }
            guard let value: Int = Int(text) else {
                return -1
            }
            return value <= 65535 ? value : -1
        }

        private static func isDigits(_ text: String) -> Bool {
            for character: Character in text {
                if !character.isASCII || !character.isNumber {
                    return false
                }
            }
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case enabled
        case useForTransport
        case useForCalls
        case selectedId
        case manual
        case subscriptions
        case advanced
    }

    public init(
        enabled: Bool = false,
        useForTransport: Bool = true,
        useForCalls: Bool = true,
        selectedId: String? = nil,
        manual: [ImpulseProxyState.Server] = [],
        subscriptions: [ImpulseProxyState.Subscription] = [],
        advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
    ) {
        self.enabled = enabled
        // At least one toggle stays on: when both are requested off, the main transport is switched back on.
        self.useForTransport = useForTransport || !useForCalls
        self.useForCalls = useForCalls
        self.selectedId = selectedId
        self.manual = manual
        self.subscriptions = subscriptions
        self.advanced = advanced
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<ImpulseProxyState.CodingKeys> = try decoder.container(keyedBy: ImpulseProxyState.CodingKeys.self)
        let version: Int32 = try container.decode(Int32.self, forKey: .version)
        guard version == ImpulseProxyState.currentVersion else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported proxy settings version"))
        }
        let enabledValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let transportValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .useForTransport)) ?? true
        let callsValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .useForCalls)) ?? true
        let selectedValue: String? = try? container.decodeIfPresent(String.self, forKey: .selectedId)
        let manualValue: [ImpulseProxyState.Server] = (try? container.decodeIfPresent([ImpulseProxyState.Server].self, forKey: .manual)) ?? []
        let subscriptionsValue: [ImpulseProxyState.Subscription] = (try? container.decodeIfPresent([ImpulseProxyState.Subscription].self, forKey: .subscriptions)) ?? []
        let advancedValue: ImpulseProxyState.Advanced = (try? container.decodeIfPresent(ImpulseProxyState.Advanced.self, forKey: .advanced)) ?? ImpulseProxyState.Advanced()
        self.init(
            enabled: enabledValue,
            useForTransport: transportValue,
            useForCalls: callsValue,
            selectedId: selectedValue,
            manual: manualValue,
            subscriptions: subscriptionsValue,
            advanced: advancedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<ImpulseProxyState.CodingKeys> = encoder.container(keyedBy: ImpulseProxyState.CodingKeys.self)
        try container.encode(ImpulseProxyState.currentVersion, forKey: .version)
        try container.encode(self.enabled, forKey: .enabled)
        try container.encode(self.useForTransport, forKey: .useForTransport)
        try container.encode(self.useForCalls, forKey: .useForCalls)
        try container.encodeIfPresent(self.selectedId, forKey: .selectedId)
        try container.encode(self.manual, forKey: .manual)
        try container.encode(self.subscriptions, forKey: .subscriptions)
        try container.encode(self.advanced, forKey: .advanced)
    }

    /// Sets both toggles. Returns false and changes nothing when both would be off.
    @discardableResult
    public mutating func setToggles(useForTransport: Bool, useForCalls: Bool) -> Bool {
        if !useForTransport && !useForCalls {
            return false
        }
        self.useForTransport = useForTransport
        self.useForCalls = useForCalls
        return true
    }
}

public struct ProxySettings: Codable, Equatable {
    public var enabled: Bool
    public var servers: [ProxyServerSettings]
    public var activeServer: ProxyServerSettings?
    public var useForCalls: Bool
    
    public static var defaultSettings: ProxySettings {
        return ProxySettings(enabled: false, servers: [], activeServer: nil, useForCalls: true)
    }
    
    public init(enabled: Bool, servers: [ProxyServerSettings], activeServer: ProxyServerSettings?, useForCalls: Bool) {
        self.enabled = enabled
        self.servers = servers
        self.activeServer = activeServer
        self.useForCalls = useForCalls
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        self.enabled = ((try? container.decode(Int32.self, forKey: "enabled")) ?? 0) != 0
        self.servers = try container.decode([ProxyServerSettings].self, forKey: "servers")
        self.activeServer = try container.decodeIfPresent(ProxyServerSettings.self, forKey: "activeServer")
        self.useForCalls = ((try? container.decode(Int32.self, forKey: "useForCalls")) ?? 1) != 0
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode((self.enabled ? 1 : 0) as Int32, forKey: "enabled")
        try container.encode(self.servers, forKey: "servers")
        try container.encodeIfPresent(self.activeServer, forKey: "activeServer")
        try container.encode((self.useForCalls ? 1 : 0) as Int32, forKey: "useForCalls")
    }
    
    public var effectiveActiveServer: ProxyServerSettings? {
        if self.enabled, let activeServer = self.activeServer {
            return activeServer
        } else {
            return nil
        }
    }
}
