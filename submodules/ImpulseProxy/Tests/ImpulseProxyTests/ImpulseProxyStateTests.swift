import XCTest
@testable import ImpulseProxy

final class ImpulseProxyStateTests: XCTestCase {
    func testEmptyObjectDecodesToDefaults() {
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: "{}")
        XCTAssertFalse(state.enabled)
        XCTAssertTrue(state.useForTransport)
        XCTAssertTrue(state.useForCalls)
        XCTAssertNil(state.selectedId)
        XCTAssertTrue(state.manual.isEmpty)
        XCTAssertTrue(state.subscriptions.isEmpty)
        XCTAssertEqual(state.advanced, ImpulseProxyState.Advanced())
    }


    func testMissingUseForCallsDefaultsToTrue() {
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: #"{"enabled":true}"#)
        XCTAssertTrue(state.useForCalls)
        XCTAssertTrue(state.useForTransport)
    }


    func testExplicitFalseUseForCallsSurvives() {
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: #"{"useForCalls":false,"useForTransport":true}"#)
        XCTAssertFalse(state.useForCalls)
        XCTAssertTrue(state.useForTransport)
    }


    func testMistypedToggleFallsBackToDefault() {
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: #"{"useForCalls":"false","useForTransport":null}"#)
        XCTAssertTrue(state.useForCalls)
        XCTAssertTrue(state.useForTransport)
    }


    func testBothTogglesOffRestoresMainTransport() {
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: #"{"useForTransport":false,"useForCalls":false}"#)
        XCTAssertTrue(state.useForTransport)
        XCTAssertFalse(state.useForCalls)
    }


    func testSetTogglesRejectsBothOff() {
        var state: ImpulseProxyState = ImpulseProxyState()
        XCTAssertFalse(state.setToggles(useForTransport: false, useForCalls: false))
        XCTAssertTrue(state.useForTransport)
        XCTAssertTrue(state.useForCalls)
        XCTAssertTrue(state.setToggles(useForTransport: false, useForCalls: true))
        XCTAssertFalse(state.useForTransport)
        XCTAssertTrue(state.useForCalls)
    }


    func testNonObjectInputDecodesToDefaults() {
        let defaults: ImpulseProxyState = ImpulseProxyState()
        XCTAssertEqual(ImpulseProxyState.decode(json: nil), defaults)
        XCTAssertEqual(ImpulseProxyState.decode(json: "[1,2]"), defaults)
        XCTAssertEqual(ImpulseProxyState.decode(json: "42"), defaults)
        XCTAssertEqual(ImpulseProxyState.decode(json: "not json"), defaults)
    }


    func testRoundTripKeepsEveryField() throws {
        let outbound: String = #"{"tag":"proxy","protocol":"vless"}"#
        let server: ImpulseProxyState.Server = ImpulseProxyState.Server(
            id: ImpulseProxyState.Server.makeId(outboundJson: outbound),
            name: "Manual",
            host: "example.com",
            port: 443,
            network: "tcp",
            security: "tls",
            outboundJson: outbound,
            shareLink: "vless://uuid@example.com:443#Manual"
        )
        let subscriptionMeta: ImpulseProxyState.SubscriptionMeta = ImpulseProxyState.SubscriptionMeta(
            title: "Panel",
            upload: 1,
            download: 2,
            total: 3,
            expire: 4,
            updateIntervalHours: 6
        )
        let subscription: ImpulseProxyState.Subscription = ImpulseProxyState.Subscription(
            id: "sub",
            url: "https://sub.example.com/list",
            meta: subscriptionMeta,
            updatedAt: 1700000000,
            lastError: nil,
            skipped: 2,
            servers: [server]
        )
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.muxEnabled = true
        advanced.fragmentMode = "classic"
        let original: ImpulseProxyState = ImpulseProxyState(
            enabled: true,
            useForTransport: true,
            useForCalls: false,
            selectedId: server.id,
            manual: [server],
            subscriptions: [subscription],
            advanced: advanced
        )
        let json: String = try original.encodedJSON()
        XCTAssertTrue(json.contains("\"v\":1"))
        XCTAssertEqual(ImpulseProxyState.decode(json: json), original)
    }


    func testMalformedServerIsSkipped() {
        let json: String = #"""
        {"manual":[
          {"id":"a","name":"A","host":"a.example","port":443,"network":"tcp","security":"none","outbound":"{}"},
          {"id":"b"}
        ]}
        """#
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: json)
        XCTAssertEqual(state.manual.count, 1)
        XCTAssertEqual(state.manual.first?.id, "a")
        XCTAssertNil(state.manual.first?.shareLink)
    }


    func testMalformedSubscriptionIsSkipped() {
        let json: String = #"{"subscriptions":[{"id":"no-url"},{"id":"ok","url":"https://ok.example/list"}]}"#
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: json)
        XCTAssertEqual(state.subscriptions.count, 1)
        XCTAssertEqual(state.subscriptions.first?.id, "ok")
    }


    func testSubscriptionMetaDefaultsWhenMissing() {
        let json: String = #"{"subscriptions":[{"id":"a","url":"https://a.example/list"}]}"#
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: json)
        let subscription: ImpulseProxyState.Subscription? = state.subscriptions.first
        XCTAssertNil(subscription?.meta.title)
        XCTAssertEqual(subscription?.meta.upload, -1)
        XCTAssertEqual(subscription?.meta.download, -1)
        XCTAssertEqual(subscription?.meta.total, -1)
        XCTAssertEqual(subscription?.meta.expire, -1)
        XCTAssertEqual(subscription?.meta.updateIntervalHours, 24)
        XCTAssertEqual(subscription?.updatedAt, 0)
        XCTAssertEqual(subscription?.skipped, 0)
    }


    func testAdvancedDefaultsMatchContract() {
        let advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        XCTAssertEqual(advanced.fragmentMode, "off")
        XCTAssertEqual(advanced.fragmentPackets, "tlshello")
        XCTAssertEqual(advanced.fragmentLength, "100-200")
        XCTAssertEqual(advanced.fragmentInterval, "10-20")
        XCTAssertTrue(advanced.fragmentFromLink)
        XCTAssertEqual(advanced.fingerprint, "")
        XCTAssertFalse(advanced.muxEnabled)
        XCTAssertEqual(advanced.muxConcurrency, 8)
        XCTAssertEqual(advanced.keepAliveIdle, 0)
        XCTAssertEqual(advanced.keepAliveInterval, 0)
        XCTAssertFalse(advanced.tcpFastOpen)
        XCTAssertEqual(advanced.tcpMaxSeg, 0)
        XCTAssertEqual(advanced.dnsMode, "system")
        XCTAssertEqual(advanced.dnsCustom, "")
        XCTAssertEqual(advanced.pingMode, "batch")
        XCTAssertEqual(advanced.pingPauseMillis, 0)
        XCTAssertEqual(advanced.pingTimeoutSeconds, 5)
        XCTAssertEqual(advanced.pingUrl, "https://www.gstatic.com/generate_204")
        XCTAssertTrue(advanced.pingSkipWhileConnected)
    }


    func testInvalidAdvancedValuesAreSanitized() {
        let json: String = #"{"advanced":{"fragmentMode":"bogus","muxConcurrency":500,"pingUrl":"http://x","dnsMode":"custom","dnsCustom":"nope","pingTimeoutSeconds":0}}"#
        let state: ImpulseProxyState = ImpulseProxyState.decode(json: json)
        XCTAssertEqual(state.advanced, ImpulseProxyState.Advanced())
    }


    func testValidAdvancedValuesAreKept() {
        let json: String = #"{"advanced":{"fragmentMode":"classic","muxConcurrency":16,"dnsMode":"custom","dnsCustom":"1.1.1.1","pingUrl":"https://example.com/204"}}"#
        let advanced: ImpulseProxyState.Advanced = ImpulseProxyState.decode(json: json).advanced
        XCTAssertEqual(advanced.fragmentMode, "classic")
        XCTAssertEqual(advanced.muxConcurrency, 16)
        XCTAssertEqual(advanced.dnsMode, "custom")
        XCTAssertEqual(advanced.dnsCustom, "1.1.1.1")
        XCTAssertEqual(advanced.pingUrl, "https://example.com/204")
    }


    func testServerIdIsFirst24HexOfSha256() {
        XCTAssertEqual(ImpulseProxyState.Server.makeId(outboundJson: ""), "e3b0c44298fc1c149afbf4c8")
        XCTAssertEqual(ImpulseProxyState.Server.makeId(outboundJson: "abc"), "ba7816bf8f01cfea414140de")
    }
}
