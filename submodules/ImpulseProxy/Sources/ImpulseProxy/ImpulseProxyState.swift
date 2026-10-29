import CryptoKit
import Foundation


/// The ImpulseM proxy configuration and its versioned JSON codec.
/// Decoding is best-effort: a malformed server or subscription is skipped and the rest of the state survives.
public struct ImpulseProxyState: Equatable, Sendable, Codable {
    /// Value written to the `v` key.
    public static let currentVersion: Int = 1

    public var enabled: Bool
    /// Main traffic goes through the Xray HTTP inbound. Missing in stored JSON means true.
    public private(set) var useForTransport: Bool
    /// LiveKit goes through the Xray SOCKS5 inbound. Missing in stored JSON means true.
    public private(set) var useForCalls: Bool
    public var selectedId: String?
    public var manual: [ImpulseProxyState.Server]
    public var subscriptions: [ImpulseProxyState.Subscription]
    public var advanced: ImpulseProxyState.Advanced


    public struct Server: Equatable, Sendable, Codable {
        public var id: String
        public var name: String
        public var host: String
        public var port: Int
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
            port: Int,
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


        /// First 24 hex digits of the SHA-256 over the outbound JSON string.
        public static func makeId(outboundJson: String) -> String {
            let digest: SHA256.Digest = SHA256.hash(data: Data(outboundJson.utf8))
            var hex: String = ""
            for byte: UInt8 in digest.prefix(12) {
                hex += String(format: "%02x", byte)
            }
            return hex
        }
    }


    public struct Subscription: Equatable, Sendable, Codable {
        public var id: String
        public var url: String
        public var meta: ImpulseProxyState.SubscriptionMeta
        public var updatedAt: Int64
        public var lastError: String?
        public var skipped: Int
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
            skipped: Int = 0,
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
            let skippedValue: Int = (try? container.decodeIfPresent(Int.self, forKey: .skipped)) ?? 0
            let serversValue: [ImpulseProxyState.Server] = container.lossyArray(ImpulseProxyState.Server.self, forKey: .servers)
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


    /// Panel headers of a subscription. Defaults: no title, -1 for every traffic value, 24 hours.
    public struct SubscriptionMeta: Equatable, Sendable, Codable {
        public var title: String?
        public var upload: Int64
        public var download: Int64
        public var total: Int64
        public var expire: Int64
        public var updateIntervalHours: Int


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
            updateIntervalHours: Int = 24
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
            let intervalValue: Int = (try? container.decodeIfPresent(Int.self, forKey: .updateIntervalHours)) ?? 24
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


    /// Advanced proxy settings. Every decoded value is sanitized to a valid one.
    public struct Advanced: Equatable, Sendable, Codable {
        public var fragmentMode: String = "off"
        public var fragmentPackets: String = "tlshello"
        public var fragmentLength: String = "100-200"
        public var fragmentInterval: String = "10-20"
        public var fragmentFromLink: Bool = true
        public var fingerprint: String = ""
        public var muxEnabled: Bool = false
        public var muxConcurrency: Int = 8
        public var keepAliveIdle: Int = 0
        public var keepAliveInterval: Int = 0
        public var tcpFastOpen: Bool = false
        public var tcpMaxSeg: Int = 0
        public var dnsMode: String = "system"
        public var dnsCustom: String = ""
        public var pingMode: String = "batch"
        public var pingPauseMillis: Int = 0
        public var pingTimeoutSeconds: Int = 5
        public var pingUrl: String = "https://www.gstatic.com/generate_204"
        public var pingSkipWhileConnected: Bool = true


        private static let fragmentModes: [String] = ["off", "classic", "finalmask"]
        private static let fingerprints: [String] = [
            "chrome",
            "firefox",
            "safari",
            "ios",
            "android",
            "edge",
            "360",
            "qq",
            "random",
            "randomized"
        ]
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
            fragmentMode = (try? container.decodeIfPresent(String.self, forKey: .fragmentMode)) ?? fragmentMode
            fragmentPackets = (try? container.decodeIfPresent(String.self, forKey: .fragmentPackets)) ?? fragmentPackets
            fragmentLength = (try? container.decodeIfPresent(String.self, forKey: .fragmentLength)) ?? fragmentLength
            fragmentInterval = (try? container.decodeIfPresent(String.self, forKey: .fragmentInterval)) ?? fragmentInterval
            fragmentFromLink = (try? container.decodeIfPresent(Bool.self, forKey: .fragmentFromLink)) ?? fragmentFromLink
            fingerprint = (try? container.decodeIfPresent(String.self, forKey: .fingerprint)) ?? fingerprint
            muxEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .muxEnabled)) ?? muxEnabled
            muxConcurrency = (try? container.decodeIfPresent(Int.self, forKey: .muxConcurrency)) ?? muxConcurrency
            keepAliveIdle = (try? container.decodeIfPresent(Int.self, forKey: .keepAliveIdle)) ?? keepAliveIdle
            keepAliveInterval = (try? container.decodeIfPresent(Int.self, forKey: .keepAliveInterval)) ?? keepAliveInterval
            tcpFastOpen = (try? container.decodeIfPresent(Bool.self, forKey: .tcpFastOpen)) ?? tcpFastOpen
            tcpMaxSeg = (try? container.decodeIfPresent(Int.self, forKey: .tcpMaxSeg)) ?? tcpMaxSeg
            dnsMode = (try? container.decodeIfPresent(String.self, forKey: .dnsMode)) ?? dnsMode
            dnsCustom = (try? container.decodeIfPresent(String.self, forKey: .dnsCustom)) ?? dnsCustom
            pingMode = (try? container.decodeIfPresent(String.self, forKey: .pingMode)) ?? pingMode
            pingPauseMillis = (try? container.decodeIfPresent(Int.self, forKey: .pingPauseMillis)) ?? pingPauseMillis
            pingTimeoutSeconds = (try? container.decodeIfPresent(Int.self, forKey: .pingTimeoutSeconds)) ?? pingTimeoutSeconds
            pingUrl = (try? container.decodeIfPresent(String.self, forKey: .pingUrl)) ?? pingUrl
            pingSkipWhileConnected = (try? container.decodeIfPresent(Bool.self, forKey: .pingSkipWhileConnected)) ?? pingSkipWhileConnected
            sanitize()
        }


        /// Replaces every invalid field with its default value.
        public mutating func sanitize() {
            if !Advanced.fragmentModes.contains(fragmentMode) {
                fragmentMode = "off"
            }
            if !Advanced.isPackets(fragmentPackets) {
                fragmentPackets = "tlshello"
            }
            if !Advanced.isRange(fragmentLength) {
                fragmentLength = "100-200"
            }
            if !Advanced.isRange(fragmentInterval) {
                fragmentInterval = "10-20"
            }
            if !fingerprint.isEmpty && !Advanced.fingerprints.contains(fingerprint) {
                fingerprint = ""
            }
            if muxConcurrency < 1 || muxConcurrency > 128 {
                muxConcurrency = 8
            }
            if keepAliveIdle < 0 || keepAliveIdle > 86400 {
                keepAliveIdle = 0
            }
            if keepAliveInterval < 0 || keepAliveInterval > 86400 {
                keepAliveInterval = 0
            }
            if tcpMaxSeg != 0 && (tcpMaxSeg < 64 || tcpMaxSeg > 1460) {
                tcpMaxSeg = 0
            }
            if !Advanced.dnsModes.contains(dnsMode) {
                dnsMode = "system"
            }
            if !dnsCustom.isEmpty && !Advanced.isDnsServer(dnsCustom) {
                dnsCustom = ""
            }
            if dnsMode == "custom" && dnsCustom.isEmpty {
                dnsMode = "system"
            }
            if !Advanced.pingModes.contains(pingMode) {
                pingMode = "batch"
            }
            if pingPauseMillis < 0 || pingPauseMillis > 10000 {
                pingPauseMillis = 0
            }
            if pingTimeoutSeconds < 1 || pingTimeoutSeconds > 30 {
                pingTimeoutSeconds = 5
            }
            if !pingUrl.hasPrefix("https://") || pingUrl.count <= "https://".count {
                pingUrl = "https://www.gstatic.com/generate_204"
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
                if part.isEmpty || part.count > 3 {
                    return false
                }
                if !isDigits(String(part)) {
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
        // At least one toggle is on. When both are off, the main transport is switched back on.
        self.useForTransport = useForTransport || !useForCalls
        self.useForCalls = useForCalls
        self.selectedId = selectedId
        self.manual = manual
        self.subscriptions = subscriptions
        self.advanced = advanced
    }


    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<ImpulseProxyState.CodingKeys> = try decoder.container(keyedBy: ImpulseProxyState.CodingKeys.self)
        let enabledValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        let transportValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .useForTransport)) ?? true
        let callsValue: Bool = (try? container.decodeIfPresent(Bool.self, forKey: .useForCalls)) ?? true
        let selectedValue: String? = try? container.decodeIfPresent(String.self, forKey: .selectedId)
        let manualValue: [ImpulseProxyState.Server] = container.lossyArray(ImpulseProxyState.Server.self, forKey: .manual)
        let subscriptionsValue: [ImpulseProxyState.Subscription] = container.lossyArray(ImpulseProxyState.Subscription.self, forKey: .subscriptions)
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
        try container.encode(enabled, forKey: .enabled)
        try container.encode(useForTransport, forKey: .useForTransport)
        try container.encode(useForCalls, forKey: .useForCalls)
        try container.encodeIfPresent(selectedId, forKey: .selectedId)
        try container.encode(manual, forKey: .manual)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(advanced, forKey: .advanced)
    }


    /// Decodes stored JSON. Missing, non-object or unparsable input gives the default state.
    public static func decode(json: String?) -> ImpulseProxyState {
        guard let json: String = json else {
            return ImpulseProxyState()
        }
        guard let data: Data = json.data(using: .utf8) else {
            return ImpulseProxyState()
        }
        do {
            return try JSONDecoder().decode(ImpulseProxyState.self, from: data)
        } catch {
            return ImpulseProxyState()
        }
    }


    public func encodedJSON() throws -> String {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }


    /// Sets both toggles. Returns false and changes nothing when both would be off.
    @discardableResult
    public mutating func setToggles(
        useForTransport: Bool,
        useForCalls: Bool
    ) -> Bool {
        if !useForTransport && !useForCalls {
            return false
        }
        self.useForTransport = useForTransport
        self.useForCalls = useForCalls
        return true
    }
}


/// Decodes one array element, or nil when that element is malformed, so the rest of the array survives.
fileprivate struct ImpulseProxyLossyItem<Element: Decodable>: Decodable {
    let value: Element?


    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}


fileprivate extension KeyedDecodingContainer {
    /// Decodes an array of elements and skips the malformed ones. A missing or non-array value gives an empty list.
    func lossyArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key
    ) -> [Element] {
        let items: [ImpulseProxyLossyItem<Element>]? = try? decodeIfPresent([ImpulseProxyLossyItem<Element>].self, forKey: key)
        guard let items: [ImpulseProxyLossyItem<Element>] = items else {
            return []
        }
        var result: [Element] = []
        for item: ImpulseProxyLossyItem<Element> in items {
            if let value: Element = item.value {
                result.append(value)
            }
        }
        return result
    }
}
