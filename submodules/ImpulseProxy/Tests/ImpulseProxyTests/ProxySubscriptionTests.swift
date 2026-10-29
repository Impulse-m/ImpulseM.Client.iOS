import Foundation
import XCTest
@testable import ImpulseProxy


final class ProxySubscriptionFakeTransport: ProxySubscriptionTransport, @unchecked Sendable {
    enum Behaviour {
        case respond(ProxySubscriptionResponse)
        case fail(Error)
        case hang
    }


    private let behaviour: Behaviour
    private(set) var userAgents: [String] = []
    private(set) var requestCount: Int = 0


    init(
        behaviour: Behaviour
    ) {
        self.behaviour = behaviour
    }


    func get(
        url: URL,
        userAgent: String,
        maxBodyBytes: Int
    ) async throws -> ProxySubscriptionResponse {
        requestCount += 1
        userAgents.append(userAgent)
        switch behaviour {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        case .hang:
            // Bounded: the fetcher cancels this sleep when its deadline passes.
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw ProxySubscriptionFailure.invalidSubscription
        }
    }
}


final class ProxySubscriptionFakeConverter: ShareLinkConverter, @unchecked Sendable {
    private let handler: @Sendable (String) throws -> [String]
    private(set) var receivedTexts: [String] = []


    init(
        handler: @escaping @Sendable (String) throws -> [String]
    ) {
        self.handler = handler
    }


    func convertShareLinks(
        text: String
    ) throws -> [String] {
        receivedTexts.append(text)
        return try handler(text)
    }
}


final class ProxySubscriptionTests: XCTestCase {
    private static let subscriptionURL: String = "https://example.com/sub?token=abc"
    private static let subscriptionId: String = "7f7830aa7abb576984fa65ba"
    private static let nowMillis: Int64 = 1_700_000_000_000
    private static let timeoutSeconds: Double = 0.05
    private static let alphaOutbound: String = #"{"protocol":"vless","settings":{"vnext":[{"address":"example.com","port":443,"users":[{"id":"11111111-2222-3333-4444-555555555555","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"none"},"tag":"Alpha"}"#
    private static let unnamedOutbound: String = #"{"protocol":"vless","settings":{"vnext":[{"address":"example.org","port":8443,"users":[]}]},"streamSettings":{"network":"ws","security":"tls"},"tag":" "}"#
    private static let shadowsocksOutbound: String = #"{"protocol":"shadowsocks","settings":{"servers":[]},"tag":"ss"}"#
    private static let addressless: String = #"{"protocol":"vless","settings":{"vnext":[{"port":443}]},"tag":"x"}"#
    private static let headerTitle: String = "TXkgVlBO"
    private static let link: String = "vless://11111111-2222-3333-4444-555555555555@example.com:443?security=none&type=tcp#Alpha"


    // MARK: Input kind

    func testDetectsBareHTTPSURLAsSubscription() {
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "https://example.com/sub"), .subscription)
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "  HTTP://example.com/sub  "), .subscription)
    }


    func testURLWithWhitespaceIsNotSubscription() {
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "https://example.com/a b"), .unknown)
    }


    func testDetectsVlessLinesOnAnyLine() {
        let text: String = "junk line\r\n  \(ProxySubscriptionTests.link)  \r\n"
        XCTAssertEqual(ProxyLinks.detectInputKind(text: text), .links)
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "VLESS://abc@host:1#x"), .links)
    }


    func testEmptyOrOtherTextIsUnknown() {
        XCTAssertEqual(ProxyLinks.detectInputKind(text: ""), .unknown)
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "   "), .unknown)
        XCTAssertEqual(ProxyLinks.detectInputKind(text: "ss://abc@host:1"), .unknown)
    }


    // MARK: Identity and headers

    func testIdIsFirst24HexOfSHA256OfTrimmedURL() {
        let id: String = ProxySubscriptionFetcher.idFor(url: "  \(ProxySubscriptionTests.subscriptionURL)\n")
        XCTAssertEqual(id, ProxySubscriptionTests.subscriptionId)
        XCTAssertEqual(id.count, 24)
    }


    func testDefaultsMatchPanelContract() {
        XCTAssertEqual(ProxySubscriptionFetcher.userAgent, "v2rayNG/1.10.0")
        XCTAssertEqual(ProxySubscriptionFetcher.defaultTimeoutSeconds, 30)
        XCTAssertEqual(ProxySubscriptionFetcher.defaultMaxBodyBytes, 4 * 1024 * 1024)
    }


    func testMetaParsesAllThreeHeaders() {
        let meta: ImpulseProxyState.SubscriptionMeta = ProxySubscriptionMeta.parse(
            profileTitle: "base64:\(ProxySubscriptionTests.headerTitle)",
            userInfo: "upload=10; download=20; total=100; expire=1700000000",
            updateInterval: "0"
        )
        XCTAssertEqual(meta.title, "My VPN")
        XCTAssertEqual(meta.upload, 10)
        XCTAssertEqual(meta.download, 20)
        XCTAssertEqual(meta.total, 100)
        XCTAssertEqual(meta.expire, 1700000000)
        XCTAssertEqual(meta.updateIntervalHours, 1)
    }


    func testMetaDefaultsWhenHeadersAreMissingOrBroken() {
        let missing: ImpulseProxyState.SubscriptionMeta = ProxySubscriptionMeta.parse(
            profileTitle: nil,
            userInfo: nil,
            updateInterval: nil
        )
        XCTAssertNil(missing.title)
        XCTAssertEqual(missing.upload, -1)
        XCTAssertEqual(missing.download, -1)
        XCTAssertEqual(missing.total, -1)
        XCTAssertEqual(missing.expire, -1)
        XCTAssertEqual(missing.updateIntervalHours, 24)
        let broken: ImpulseProxyState.SubscriptionMeta = ProxySubscriptionMeta.parse(
            profileTitle: "base64:!!!",
            userInfo: "upload=abc",
            updateInterval: "abc"
        )
        XCTAssertNil(broken.title)
        XCTAssertEqual(broken.upload, -1)
        XCTAssertEqual(broken.updateIntervalHours, 24)
    }


    func testHeaderLookupIsCaseInsensitive() {
        let response: ProxySubscriptionResponse = ProxySubscriptionResponse(
            statusCode: 200,
            headers: ["Profile-Title": "Plain"],
            body: Data()
        )
        XCTAssertEqual(response.headerValue(name: "profile-title"), "Plain")
    }


    // MARK: Fetch

    func testSuccessKeepsVlessServersAndCountsSkipped() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: "body"))
        )
        let converter: ProxySubscriptionFakeConverter = ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
            return [
                ProxySubscriptionTests.alphaOutbound,
                ProxySubscriptionTests.shadowsocksOutbound,
                ProxySubscriptionTests.unnamedOutbound,
                ProxySubscriptionTests.addressless
            ]
        })
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(transport: transport, converter: converter)
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertNil(result.lastError)
        XCTAssertEqual(result.id, ProxySubscriptionTests.subscriptionId)
        XCTAssertEqual(result.updatedAt, ProxySubscriptionTests.nowMillis)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.servers.count, 2)
        XCTAssertEqual(result.servers[0].name, "Alpha")
        XCTAssertEqual(result.servers[0].host, "example.com")
        XCTAssertEqual(result.servers[0].port, 443)
        XCTAssertEqual(result.servers[0].network, "tcp")
        XCTAssertEqual(result.servers[0].security, "none")
        XCTAssertEqual(result.servers[0].id, ImpulseProxyState.Server.makeId(outboundJson: ProxySubscriptionTests.alphaOutbound))
        XCTAssertNil(result.servers[0].shareLink)
        XCTAssertEqual(result.servers[1].name, "example.org")
        XCTAssertEqual(result.servers[1].network, "ws")
        XCTAssertEqual(result.servers[1].security, "tls")
    }


    func testRequestUsesPanelUserAgent() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: ProxySubscriptionTests.link))
        )
        let converter: ProxySubscriptionFakeConverter = ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
            return [ProxySubscriptionTests.alphaOutbound]
        })
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(transport: transport, converter: converter)
        _ = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(transport.userAgents, ["v2rayNG/1.10.0"])
    }


    func testByteOrderMarkIsStrippedBeforeConversion() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: "\u{FEFF}\(ProxySubscriptionTests.link)"))
        )
        let converter: ProxySubscriptionFakeConverter = ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
            return [ProxySubscriptionTests.alphaOutbound]
        })
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(transport: transport, converter: converter)
        _ = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(converter.receivedTexts, [ProxySubscriptionTests.link])
    }


    func testHTTPErrorKeepsPreviousServersAndMeta() async throws {
        let previous: ImpulseProxyState.Subscription = try await makeSuccessfulSubscription()
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(status: 404, body: "gone"))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: previous,
            nowMillis: ProxySubscriptionTests.nowMillis + 1
        )
        XCTAssertEqual(result.lastError, "err:http:404")
        XCTAssertEqual(result.servers, previous.servers)
        XCTAssertEqual(result.meta, previous.meta)
        XCTAssertEqual(result.skipped, previous.skipped)
        XCTAssertEqual(result.updatedAt, ProxySubscriptionTests.nowMillis + 1)
    }


    func testFailureWithoutPreviousStoresNoServers() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(status: 500, body: ""))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:http:500")
        XCTAssertTrue(result.servers.isEmpty)
    }


    func testTransportErrorGivesNetworkCode() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .fail(URLError(.notConnectedToInternet))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:network")
    }


    func testDeadlineGivesNetworkCode() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(behaviour: .hang)
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            }),
            timeoutSeconds: ProxySubscriptionTests.timeoutSeconds
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:network")
    }


    func testOversizedBodyIsInvalidSubscription() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: String(repeating: "a", count: 17)))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            }),
            maxBodyBytes: 16
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:invalidSubscription")
    }


    func testNoValidOutboundGivesNoLinks() async throws {
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: ProxySubscriptionFakeTransport(behaviour: .respond(makeResponse(body: "nothing"))),
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) throws -> [String] in
                throw LibXrayError.methodFailed(
                    method: "convertShareLinksToXrayJson",
                    message: "No valid outbound found"
                )
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:noLinks")
    }


    func testOtherConversionFailureGivesInvalidSubscription() async throws {
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: ProxySubscriptionFakeTransport(behaviour: .respond(makeResponse(body: "bad"))),
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) throws -> [String] in
                throw LibXrayError.malformedResponse(method: "convertShareLinksToXrayJson")
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:invalidSubscription")
    }


    func testOnlySkippedOutboundsGiveNoLinksWithCount() async throws {
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: ProxySubscriptionFakeTransport(behaviour: .respond(makeResponse(body: "ss"))),
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return [ProxySubscriptionTests.shadowsocksOutbound, ProxySubscriptionTests.shadowsocksOutbound]
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:noLinks:2")
    }


    func testNonHTTPURLIsInvalidAndNeverRequested() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: "x"))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: "ftp://example.com/sub",
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:invalidSubscription")
        XCTAssertEqual(transport.requestCount, 0)
    }


    func testURLWithoutHostIsInvalidAndNeverRequested() async throws {
        let transport: ProxySubscriptionFakeTransport = ProxySubscriptionFakeTransport(
            behaviour: .respond(makeResponse(body: "x"))
        )
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: transport,
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return []
            })
        )
        let result: ImpulseProxyState.Subscription = try await fetcher.fetch(
            url: "https://",
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
        XCTAssertEqual(result.lastError, "err:invalidSubscription")
        XCTAssertEqual(transport.requestCount, 0)
    }


    // MARK: Manual links

    func testManualLinesAreConvertedOneByOne() {
        let converter: ProxySubscriptionFakeConverter = ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
            return [ProxySubscriptionTests.alphaOutbound]
        })
        let servers: [ImpulseProxyState.Server] = ProxyLinks.parseLinks(
            text: "ss://abc@host:1\n  \(ProxySubscriptionTests.link)  \n",
            converter: converter
        )
        XCTAssertEqual(converter.receivedTexts, [ProxySubscriptionTests.link])
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].shareLink, ProxySubscriptionTests.link)
    }


    func testManualLineThatLibXrayRejectsIsDropped() {
        let good: String = "vless://good@example.com:443#Good"
        let bad: String = "vless://bad@example.com:443#Bad"
        let converter: ProxySubscriptionFakeConverter = ProxySubscriptionFakeConverter(handler: { (text: String) throws -> [String] in
            if text == bad {
                throw LibXrayError.methodFailed(method: "convertShareLinksToXrayJson", message: "bad link")
            }
            return [ProxySubscriptionTests.alphaOutbound]
        })
        let servers: [ImpulseProxyState.Server] = ProxyLinks.parseLinks(
            text: "\(bad)\n\(good)",
            converter: converter
        )
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].shareLink, good)
    }


    // MARK: Helpers

    private func makeResponse(
        status: Int = 200,
        body: String
    ) -> ProxySubscriptionResponse {
        return ProxySubscriptionResponse(
            statusCode: status,
            headers: [
                "profile-title": ProxySubscriptionTests.headerTitle,
                "subscription-userinfo": "upload=1; download=2; total=3; expire=4",
                "profile-update-interval": "6"
            ],
            body: Data(body.utf8)
        )
    }


    private func makeSuccessfulSubscription() async throws -> ImpulseProxyState.Subscription {
        let fetcher: ProxySubscriptionFetcher = ProxySubscriptionFetcher(
            transport: ProxySubscriptionFakeTransport(behaviour: .respond(makeResponse(body: "ok"))),
            converter: ProxySubscriptionFakeConverter(handler: { (_: String) -> [String] in
                return [ProxySubscriptionTests.alphaOutbound, ProxySubscriptionTests.shadowsocksOutbound]
            })
        )
        return try await fetcher.fetch(
            url: ProxySubscriptionTests.subscriptionURL,
            previous: nil,
            nowMillis: ProxySubscriptionTests.nowMillis
        )
    }
}
