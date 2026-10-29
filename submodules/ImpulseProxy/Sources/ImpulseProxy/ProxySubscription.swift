import CryptoKit
import Foundation


/// Why a subscription fetch failed. `code` is the stored, language-neutral error code.
public enum ProxySubscriptionFailure: Error, Equatable, Sendable {
    case http(statusCode: Int)
    case network
    case invalidSubscription
    case noLinks(skipped: Int)


    public var code: String {
        switch self {
        case .http(let statusCode):
            return "err:http:\(statusCode)"
        case .network:
            return "err:network"
        case .invalidSubscription:
            return "err:invalidSubscription"
        case .noLinks(let skipped):
            return skipped > 0 ? "err:noLinks:\(skipped)" : "err:noLinks"
        }
    }
}


/// The result of one subscription GET. The body holds at most `maxBodyBytes + 1` bytes.
public struct ProxySubscriptionResponse: Equatable, Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data


    public init(
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }


    /// Case-insensitive header lookup.
    public func headerValue(
        name: String
    ) -> String? {
        let wanted: String = name.lowercased()
        for (key, value): (String, String) in headers {
            if key.lowercased() == wanted {
                return value
            }
        }
        return nil
    }
}


/// Performs the subscription GET. Implementations stop reading the body after `maxBodyBytes + 1` bytes
/// and finish promptly when the calling task is cancelled.
public protocol ProxySubscriptionTransport: Sendable {
    func get(
        url: URL,
        userAgent: String,
        maxBodyBytes: Int
    ) async throws -> ProxySubscriptionResponse
}


/// Subscription transport over URLSession. Pass a session that routes through the Xray HTTP inbound
/// when the main transport is proxied.
public struct ProxySubscriptionSessionTransport: ProxySubscriptionTransport {
    private let session: URLSession


    public init(
        session: URLSession
    ) {
        self.session = session
    }


    public func get(
        url: URL,
        userAgent: String,
        maxBodyBytes: Int
    ) async throws -> ProxySubscriptionResponse {
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await session.bytes(for: request)
        guard let httpResponse: HTTPURLResponse = response as? HTTPURLResponse else {
            throw ProxySubscriptionFailure.network
        }
        var body: Data = Data()
        for try await byte: UInt8 in bytes {
            body.append(byte)
            if body.count > maxBodyBytes {
                break
            }
        }
        var headers: [String: String] = [:]
        for (key, value): (AnyHashable, Any) in httpResponse.allHeaderFields {
            if let name: String = key as? String, let text: String = value as? String {
                headers[name] = text
            }
        }
        return ProxySubscriptionResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: body
        )
    }
}


/// Parses the panel headers of a subscription: profile-title, subscription-userinfo and profile-update-interval.
public enum ProxySubscriptionMeta {
    public static let defaultIntervalHours: Int = 24
    private static let base64Prefix: String = "base64:"


    public static func parse(
        profileTitle: String?,
        userInfo: String?,
        updateInterval: String?
    ) -> ImpulseProxyState.SubscriptionMeta {
        var interval: Int = defaultIntervalHours
        if let value: String = updateInterval {
            let trimmed: String = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed: Int = Int(trimmed) {
                interval = max(1, parsed)
            }
        }
        return ImpulseProxyState.SubscriptionMeta(
            title: parseTitle(profileTitle),
            upload: userInfoValue(userInfo, key: "upload"),
            download: userInfoValue(userInfo, key: "download"),
            total: userInfoValue(userInfo, key: "total"),
            expire: userInfoValue(userInfo, key: "expire"),
            updateIntervalHours: interval
        )
    }


    private static func parseTitle(
        _ header: String?
    ) -> String? {
        guard let header: String = header else {
            return nil
        }
        let value: String = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return nil
        }
        if !value.hasPrefix(base64Prefix) {
            return value
        }
        let encoded: String = String(value.dropFirst(base64Prefix.count))
        guard let data: Data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            return nil
        }
        let decoded: String = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }


    /// Reads `key=value` pairs separated by `;`. Missing or malformed values are -1.
    private static func userInfoValue(
        _ header: String?,
        key: String
    ) -> Int64 {
        guard let header: String = header else {
            return -1
        }
        let wanted: String = key.lowercased()
        for part: String in header.components(separatedBy: ";") {
            let trimmedPart: String = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator: String.Index = trimmedPart.firstIndex(of: "=") else {
                continue
            }
            let name: String = String(trimmedPart[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            if name.lowercased() != wanted {
                continue
            }
            let valueStart: String.Index = trimmedPart.index(after: separator)
            let valueText: String = String(trimmedPart[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Int64(valueText) ?? -1
        }
        return -1
    }
}


/// Downloads one VLESS subscription and turns it into stored servers. A failed fetch keeps the previous servers.
public struct ProxySubscriptionFetcher: Sendable {
    /// Total time allowed for one fetch, including the body.
    public static let defaultTimeoutSeconds: Double = 30
    /// Largest accepted body.
    public static let defaultMaxBodyBytes: Int = 4 * 1024 * 1024
    /// User agent the subscription panels expect.
    public static let userAgent: String = "v2rayNG/1.10.0"

    private static let idLength: Int = 24
    private static let noValidOutboundMarker: String = "no valid outbound"

    private let transport: ProxySubscriptionTransport
    private let converter: ShareLinkConverter
    private let timeoutSeconds: Double
    private let maxBodyBytes: Int


    public init(
        transport: ProxySubscriptionTransport,
        converter: ShareLinkConverter,
        timeoutSeconds: Double = ProxySubscriptionFetcher.defaultTimeoutSeconds,
        maxBodyBytes: Int = ProxySubscriptionFetcher.defaultMaxBodyBytes
    ) {
        self.transport = transport
        self.converter = converter
        self.timeoutSeconds = timeoutSeconds
        self.maxBodyBytes = maxBodyBytes
    }


    /// Stable per URL: the first 24 hex characters of the SHA-256 of the trimmed URL.
    public static func idFor(
        url: String
    ) -> String {
        let trimmed: String = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest: SHA256.Digest = SHA256.hash(data: Data(trimmed.utf8))
        var hex: String = ""
        for byte: UInt8 in digest {
            hex += String(format: "%02x", byte)
        }
        return String(hex.prefix(idLength))
    }


    /// Fetches the subscription. On failure the result keeps the previous meta and servers and sets `lastError`.
    /// Throws CancellationError when the calling task is cancelled, and then produces no result.
    public func fetch(
        url: String,
        previous: ImpulseProxyState.Subscription?,
        nowMillis: Int64
    ) async throws -> ImpulseProxyState.Subscription {
        let trimmed: String = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String = ProxySubscriptionFetcher.idFor(url: trimmed)
        do {
            return try await download(
                url: trimmed,
                id: id,
                nowMillis: nowMillis
            )
        } catch {
            try Task.checkCancellation()
            let code: String = (error as? ProxySubscriptionFailure)?.code ?? ProxySubscriptionFailure.network.code
            return ProxySubscriptionFetcher.failed(
                previous: previous,
                id: id,
                url: trimmed,
                nowMillis: nowMillis,
                code: code
            )
        }
    }


    private func download(
        url: String,
        id: String,
        nowMillis: Int64
    ) async throws -> ImpulseProxyState.Subscription {
        guard let requestURL: URL = ProxySubscriptionFetcher.httpURL(string: url) else {
            throw ProxySubscriptionFailure.invalidSubscription
        }
        let response: ProxySubscriptionResponse = try await getWithDeadline(url: requestURL)
        if !(200...299).contains(response.statusCode) {
            throw ProxySubscriptionFailure.http(statusCode: response.statusCode)
        }
        if response.body.count > maxBodyBytes {
            throw ProxySubscriptionFailure.invalidSubscription
        }
        var text: String = String(decoding: response.body, as: UTF8.self)
        if text.first == "\u{FEFF}" {
            text.removeFirst()
        }
        let meta: ImpulseProxyState.SubscriptionMeta = ProxySubscriptionMeta.parse(
            profileTitle: response.headerValue(name: "profile-title"),
            userInfo: response.headerValue(name: "subscription-userinfo"),
            updateInterval: response.headerValue(name: "profile-update-interval")
        )
        let outbounds: [String]
        do {
            outbounds = try converter.convertShareLinks(text: text)
        } catch {
            if ProxySubscriptionFetcher.isNoValidOutbound(error) {
                throw ProxySubscriptionFailure.noLinks(skipped: 0)
            }
            throw ProxySubscriptionFailure.invalidSubscription
        }
        let filtered: ProxyOutboundFilterResult = ProxyOutboundFilter.filter(outbounds: outbounds)
        if filtered.servers.isEmpty {
            throw ProxySubscriptionFailure.noLinks(skipped: filtered.skipped)
        }
        return ImpulseProxyState.Subscription(
            id: id,
            url: url,
            meta: meta,
            updatedAt: nowMillis,
            lastError: nil,
            skipped: filtered.skipped,
            servers: filtered.servers
        )
    }


    /// Races the transport against the total timeout. The timeout reports `err:network`, as an interrupted call does.
    private func getWithDeadline(
        url: URL
    ) async throws -> ProxySubscriptionResponse {
        let transport: ProxySubscriptionTransport = self.transport
        let maxBytes: Int = maxBodyBytes
        let timeoutNanoseconds: UInt64 = UInt64(timeoutSeconds * 1_000_000_000)
        return try await withThrowingTaskGroup(
            of: ProxySubscriptionResponse.self,
            returning: ProxySubscriptionResponse.self
        ) { (group: inout ThrowingTaskGroup<ProxySubscriptionResponse, Error>) async throws -> ProxySubscriptionResponse in
            group.addTask { () async throws -> ProxySubscriptionResponse in
                return try await transport.get(
                    url: url,
                    userAgent: ProxySubscriptionFetcher.userAgent,
                    maxBodyBytes: maxBytes
                )
            }
            group.addTask { () async throws -> ProxySubscriptionResponse in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ProxySubscriptionFailure.network
            }
            guard let first: ProxySubscriptionResponse = try await group.next() else {
                throw ProxySubscriptionFailure.network
            }
            group.cancelAll()
            return first
        }
    }


    private static func httpURL(
        string: String
    ) -> URL? {
        guard let url: URL = URL(string: string) else {
            return nil
        }
        guard let scheme: String = url.scheme?.lowercased() else {
            return nil
        }
        if scheme != "http" && scheme != "https" {
            return nil
        }
        guard let host: String = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }


    private static func isNoValidOutbound(
        _ error: Error
    ) -> Bool {
        guard let libXrayError: LibXrayError = error as? LibXrayError else {
            return false
        }
        guard case .methodFailed(_, let message) = libXrayError else {
            return false
        }
        return message.lowercased().contains(noValidOutboundMarker)
    }


    private static func failed(
        previous: ImpulseProxyState.Subscription?,
        id: String,
        url: String,
        nowMillis: Int64,
        code: String
    ) -> ImpulseProxyState.Subscription {
        guard let previous: ImpulseProxyState.Subscription = previous else {
            return ImpulseProxyState.Subscription(
                id: id,
                url: url,
                updatedAt: nowMillis,
                lastError: code
            )
        }
        return ImpulseProxyState.Subscription(
            id: id,
            url: url,
            meta: previous.meta,
            updatedAt: nowMillis,
            lastError: code,
            skipped: previous.skipped,
            servers: previous.servers
        )
    }
}
