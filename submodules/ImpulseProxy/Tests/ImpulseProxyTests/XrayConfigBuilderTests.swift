import Foundation
import XCTest
@testable import ImpulseProxy


final class XrayConfigBuilderTests: XCTestCase {
    private static let inbounds: LocalInbounds = LocalInbounds(
        httpPort: 1,
        socksPort: 2,
        user: "u",
        password: "p"
    )
    private static let linkBase: String = "vless://u@h.example:443?type=tcp&fragment="

    /// Golden outbounds produced before the advanced settings existed.
    private static let goldenTlsOutbound: String = #"""
    {"protocol":"vless","tag":"proxy","settings":{"vnext":[{"address":"h.example","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"a"}}}
    """#
    private static let goldenRealityOutbound: String = #"""
    {"protocol":"vless","tag":"proxy","settings":{"vnext":[{"address":"h.example","port":443,"users":[{"id":"11111111-1111-1111-1111-111111111111","encryption":"none","flow":"xtls-rprx-vision"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"s","fingerprint":"chrome","publicKey":"k","shortId":"ab"}}}
    """#


    func testInboundsListenOnLoopbackWithAccounts() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(
                server: server,
                inbounds: LocalInbounds(
                    httpPort: 41001,
                    socksPort: 41002,
                    user: "u1",
                    password: "p1"
                )
            )
        )
        let inboundList: [[String: Any]] = try XCTUnwrap(config["inbounds"] as? [[String: Any]])
        let http: [String: Any] = inboundList[0]
        let socks: [String: Any] = inboundList[1]
        XCTAssertEqual(http["protocol"] as? String, "http")
        XCTAssertEqual(http["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(http["port"] as? Int, 41001)
        let httpSettings: [String: Any] = try XCTUnwrap(http["settings"] as? [String: Any])
        let httpAccounts: [[String: Any]] = try XCTUnwrap(httpSettings["accounts"] as? [[String: Any]])
        XCTAssertEqual(httpAccounts[0]["user"] as? String, "u1")
        XCTAssertEqual(httpSettings["allowTransparent"] as? Bool, false)
        XCTAssertEqual(socks["protocol"] as? String, "socks")
        XCTAssertEqual(socks["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(socks["port"] as? Int, 41002)
        let socksSettings: [String: Any] = try XCTUnwrap(socks["settings"] as? [String: Any])
        XCTAssertEqual(socksSettings["auth"] as? String, "password")
        XCTAssertEqual(socksSettings["udp"] as? Bool, true)
        XCTAssertEqual(socksSettings["ip"] as? String, "127.0.0.1")
        let socksAccounts: [[String: Any]] = try XCTUnwrap(socksSettings["accounts"] as? [[String: Any]])
        XCTAssertEqual(socksAccounts[0]["pass"] as? String, "p1")
    }


    func testCoreLogsErrorsOnlyAndAccessLogIsOff() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds)
        )
        let log: [String: Any] = try XCTUnwrap(config["log"] as? [String: Any])
        XCTAssertEqual(log["loglevel"] as? String, "error")
        XCTAssertEqual(log["access"] as? String, "none")
    }


    func testEverythingRoutesToTheProxyOutbound() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds)
        )
        let first: [String: Any] = try XrayConfigBuilderTests.outbound(config, 0)
        XCTAssertEqual(first["tag"] as? String, "proxy")
        XCTAssertEqual(first["protocol"] as? String, "vless")
        let routing: [String: Any] = try XCTUnwrap(config["routing"] as? [String: Any])
        XCTAssertEqual(routing["domainStrategy"] as? String, "AsIs")
        let rules: [[String: Any]] = try XCTUnwrap(routing["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["outboundTag"] as? String, "proxy")
        XCTAssertEqual(rules[0]["inboundTag"] as? [String], ["http-in", "socks-in"])
    }


    func testOriginalTagIsNotInTheConfig() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "Name With Secrets?"
        )
        let config: String = try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds)
        XCTAssertFalse(config.contains("Name With Secrets?"))
    }


    func testPingConfigHasOnlyTheTaggedOutbound() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: server)
        )
        let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        XCTAssertEqual(outbounds[0]["tag"] as? String, "proxy")
        XCTAssertNil(config["inbounds"])
    }


    func testEmptyPasswordIsRejected() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let inbounds: LocalInbounds = LocalInbounds(
            httpPort: 1,
            socksPort: 2,
            user: "u",
            password: ""
        )
        XCTAssertThrowsError(try XrayConfigBuilder.build(server: server, inbounds: inbounds)) { (error: Error) -> Void in
            XCTAssertEqual(error as? XrayConfigError, XrayConfigError.emptyCredential(name: "password"))
        }
    }


    func testEmptyUserIsRejected() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let inbounds: LocalInbounds = LocalInbounds(
            httpPort: 1,
            socksPort: 2,
            user: "",
            password: "p"
        )
        XCTAssertThrowsError(try XrayConfigBuilder.build(server: server, inbounds: inbounds)) { (error: Error) -> Void in
            XCTAssertEqual(error as? XrayConfigError, XrayConfigError.emptyCredential(name: "user"))
        }
    }


    func testDefaultAdvancedReproducesThePreChangeOutput() throws {
        let inbounds: LocalInbounds = LocalInbounds(
            httpPort: 41001,
            socksPort: 41002,
            user: "u",
            password: "p"
        )
        let tls: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"tls","tlsSettings":{"serverName":"a"}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let reality: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"reality","realitySettings":{"serverName":"s","fingerprint":"chrome","publicKey":"k","shortId":"ab"}}"#,
            flow: "xtls-rprx-vision",
            shareLink: nil,
            tag: "t"
        )
        let goldenTlsRun: String = try XrayConfigBuilderTests.canonical(
            XrayConfigBuilderTests.goldenBuild(outbound: XrayConfigBuilderTests.goldenTlsOutbound)
        )
        let goldenRealityRun: String = try XrayConfigBuilderTests.canonical(
            XrayConfigBuilderTests.goldenBuild(outbound: XrayConfigBuilderTests.goldenRealityOutbound)
        )
        let goldenTlsPing: String = try XrayConfigBuilderTests.canonical(
            #"{"outbounds":[\#(XrayConfigBuilderTests.goldenTlsOutbound)]}"#
        )
        let goldenRealityPing: String = try XrayConfigBuilderTests.canonical(
            #"{"outbounds":[\#(XrayConfigBuilderTests.goldenRealityOutbound)]}"#
        )
        let builtTls: String = try XrayConfigBuilderTests.canonical(
            try XrayConfigBuilder.build(server: tls, inbounds: inbounds)
        )
        let builtTlsDefault: String = try XrayConfigBuilderTests.canonical(
            try XrayConfigBuilder.build(server: tls, inbounds: inbounds, advanced: ImpulseProxyState.Advanced())
        )
        let builtReality: String = try XrayConfigBuilderTests.canonical(
            try XrayConfigBuilder.build(server: reality, inbounds: inbounds)
        )
        let pingTls: String = try XrayConfigBuilderTests.canonical(try XrayConfigBuilder.pingConfig(server: tls))
        let pingReality: String = try XrayConfigBuilderTests.canonical(
            try XrayConfigBuilder.pingConfig(server: reality, advanced: ImpulseProxyState.Advanced())
        )
        XCTAssertEqual(builtTls, goldenTlsRun)
        XCTAssertEqual(builtTlsDefault, goldenTlsRun)
        XCTAssertEqual(builtReality, goldenRealityRun)
        XCTAssertEqual(pingTls, goldenTlsPing)
        XCTAssertEqual(pingReality, goldenRealityPing)
    }


    func testNilAdvancedEqualsDefaultAdvanced() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"tls","tlsSettings":{}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let runNil: String = try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: nil)
        let runDefault: String = try XrayConfigBuilder.build(
            server: server,
            inbounds: XrayConfigBuilderTests.inbounds,
            advanced: ImpulseProxyState.Advanced()
        )
        XCTAssertEqual(runNil, runDefault)
        let pingNil: String = try XrayConfigBuilder.pingConfig(server: server, advanced: nil)
        let pingDefault: String = try XrayConfigBuilder.pingConfig(server: server)
        XCTAssertEqual(pingNil, pingDefault)
    }


    func testClassicFragmentKeepsExistingSockoptKeys() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "classic"
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","sockopt":{"mark":255}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let options: [String: Any] = try XrayConfigBuilderTests.sockopt(try XrayConfigBuilderTests.outbound(config, 0))
        XCTAssertEqual(options["mark"] as? Int, 255)
        XCTAssertEqual(options["dialerProxy"] as? String, "fragment")
    }


    func testClassicFragmentUsesAFreedomDialer() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "classic"
        advanced.fragmentPackets = "1-3"
        advanced.fragmentLength = "10-20"
        advanced.fragmentInterval = "5-6"
        advanced.keepAliveIdle = 30
        advanced.keepAliveInterval = 10
        advanced.tcpFastOpen = true
        advanced.tcpMaxSeg = 1300
        advanced.dnsMode = "google"
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let proxy: [String: Any] = try XrayConfigBuilderTests.outbound(config, 0)
        let freedom: [String: Any] = try XrayConfigBuilderTests.outbound(config, 1)
        XCTAssertEqual(proxy["tag"] as? String, "proxy")
        let proxyOptions: [String: Any] = try XrayConfigBuilderTests.sockopt(proxy)
        XCTAssertEqual(proxyOptions.count, 1)
        XCTAssertEqual(proxyOptions["dialerProxy"] as? String, "fragment")
        XCTAssertEqual(freedom["tag"] as? String, "fragment")
        XCTAssertEqual(freedom["protocol"] as? String, "freedom")
        let freedomSettings: [String: Any] = try XCTUnwrap(freedom["settings"] as? [String: Any])
        let fragment: [String: Any] = try XCTUnwrap(freedomSettings["fragment"] as? [String: Any])
        XCTAssertEqual(fragment["packets"] as? String, "1-3")
        XCTAssertEqual(fragment["length"] as? String, "10-20")
        XCTAssertEqual(fragment["interval"] as? String, "5-6")
        XCTAssertEqual(freedomSettings["domainStrategy"] as? String, "UseIPv4")
        let freedomOptions: [String: Any] = try XrayConfigBuilderTests.sockopt(freedom)
        XCTAssertEqual(freedomOptions["tcpKeepAliveIdle"] as? Int, 30)
        XCTAssertEqual(freedomOptions["tcpKeepAliveInterval"] as? Int, 10)
        XCTAssertEqual(freedomOptions["tcpFastOpen"] as? Bool, true)
        XCTAssertEqual(freedomOptions["tcpMaxSeg"] as? Int, 1300)
        let proxyStream: [String: Any] = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
        XCTAssertNil(proxyStream["finalmask"])
    }


    func testFinalMaskFragmentIsOnTheProxyStream() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "finalmask"
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        let stream: [String: Any] = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        let finalMask: [String: Any] = try XCTUnwrap(stream["finalmask"] as? [String: Any])
        let tcp: [[String: Any]] = try XCTUnwrap(finalMask["tcp"] as? [[String: Any]])
        XCTAssertEqual(tcp.count, 1)
        XCTAssertEqual(tcp[0]["type"] as? String, "fragment")
        let settings: [String: Any] = try XCTUnwrap(tcp[0]["settings"] as? [String: Any])
        XCTAssertEqual(settings["packets"] as? String, "tlshello")
        XCTAssertEqual(settings["lengths"] as? [String], ["100-200"])
        XCTAssertEqual(settings["delays"] as? [String], ["10-20"])
    }


    func testFingerprintOverridesTlsAndReality() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fingerprint = "firefox"
        let tlsServer: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"tls","tlsSettings":{"fingerprint":"chrome"}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let tlsConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: tlsServer, advanced: advanced)
        )
        let tlsStream: [String: Any] = try XCTUnwrap(
            XrayConfigBuilderTests.outbound(tlsConfig, 0)["streamSettings"] as? [String: Any]
        )
        let tlsSettings: [String: Any] = try XCTUnwrap(tlsStream["tlsSettings"] as? [String: Any])
        XCTAssertEqual(tlsSettings["fingerprint"] as? String, "firefox")
        XCTAssertNil(tlsStream["realitySettings"])
        let realityServer: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"reality","realitySettings":{"serverName":"s"}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let realityConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: realityServer, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let realityStream: [String: Any] = try XCTUnwrap(
            XrayConfigBuilderTests.outbound(realityConfig, 0)["streamSettings"] as? [String: Any]
        )
        let realitySettings: [String: Any] = try XCTUnwrap(realityStream["realitySettings"] as? [String: Any])
        XCTAssertEqual(realitySettings["fingerprint"] as? String, "firefox")
        XCTAssertNil(realityStream["tlsSettings"])
    }


    func testMuxIsAddedExceptForVision() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.muxEnabled = true
        advanced.muxConcurrency = 4
        let plain: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let plainConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: plain, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let mux: [String: Any] = try XCTUnwrap(
            XrayConfigBuilderTests.outbound(plainConfig, 0)["mux"] as? [String: Any]
        )
        XCTAssertEqual(mux["enabled"] as? Bool, true)
        XCTAssertEqual(mux["concurrency"] as? Int, 4)
        let vision: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: "xtls-rprx-vision",
            shareLink: nil,
            tag: "t"
        )
        let visionConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: vision, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        XCTAssertNil(try XrayConfigBuilderTests.outbound(visionConfig, 0)["mux"])
        let visionUdp: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: "xtls-rprx-vision-udp443",
            shareLink: nil,
            tag: "t"
        )
        let visionUdpConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: visionUdp, advanced: advanced)
        )
        XCTAssertNil(try XrayConfigBuilderTests.outbound(visionUdpConfig, 0)["mux"])
    }


    func testTcpOptionsGoOnTheProxySockoptWithoutClassicFragment() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.keepAliveIdle = 20
        advanced.tcpMaxSeg = 1200
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let options: [String: Any] = try XrayConfigBuilderTests.sockopt(try XrayConfigBuilderTests.outbound(config, 0))
        XCTAssertEqual(options["tcpKeepAliveIdle"] as? Int, 20)
        XCTAssertEqual(options["tcpMaxSeg"] as? Int, 1200)
        XCTAssertNil(options["tcpKeepAliveInterval"])
        XCTAssertNil(options["tcpFastOpen"])
        advanced.fragmentMode = "finalmask"
        let maskedConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let masked: [String: Any] = try XrayConfigBuilderTests.sockopt(try XrayConfigBuilderTests.outbound(maskedConfig, 0))
        XCTAssertEqual(masked["tcpKeepAliveIdle"] as? Int, 20)
    }


    func testDnsAddsTheTopLevelObjectAndDomainStrategy() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.dnsMode = "custom"
        advanced.dnsCustom = "8.8.4.4"
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let built: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let ping: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: server, advanced: advanced)
        )
        let expected: String = try XrayConfigBuilderTests.canonical(#"{"servers":["8.8.4.4"],"queryStrategy":"UseIPv4"}"#)
        let builtDns: [String: Any] = try XCTUnwrap(built["dns"] as? [String: Any])
        let pingDns: [String: Any] = try XCTUnwrap(ping["dns"] as? [String: Any])
        XCTAssertEqual(try XrayConfigBuilderTests.canonical(try XrayConfigBuilderTests.jsonText(builtDns)), expected)
        XCTAssertEqual(try XrayConfigBuilderTests.canonical(try XrayConfigBuilderTests.jsonText(pingDns)), expected)
        let options: [String: Any] = try XrayConfigBuilderTests.sockopt(try XrayConfigBuilderTests.outbound(built, 0))
        XCTAssertEqual(options["domainStrategy"] as? String, "UseIPv4")
        let plain: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds)
        )
        XCTAssertNil(plain["dns"])
    }


    func testLinkFragmentIsHonouredWhenModeIsOffAndFromLinkIsOn() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: XrayConfigBuilderTests.linkBase + "1-10%2C5-20%2Ctlshello%2C3#name",
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: ImpulseProxyState.Advanced())
        )
        let options: [String: Any] = try XrayConfigBuilderTests.sockopt(try XrayConfigBuilderTests.outbound(config, 0))
        XCTAssertEqual(options["dialerProxy"] as? String, "fragment")
        let freedom: [String: Any] = try XrayConfigBuilderTests.outbound(config, 1)
        let freedomSettings: [String: Any] = try XCTUnwrap(freedom["settings"] as? [String: Any])
        let fragment: [String: Any] = try XCTUnwrap(freedomSettings["fragment"] as? [String: Any])
        XCTAssertEqual(fragment["packets"] as? String, "tlshello")
        XCTAssertEqual(fragment["length"] as? String, "1-10")
        XCTAssertEqual(fragment["interval"] as? String, "5-20")
        let plainComma: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: XrayConfigBuilderTests.linkBase + "1-10,5-20,tlshello",
            tag: "t"
        )
        let pingConfig: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: plainComma, advanced: ImpulseProxyState.Advanced())
        )
        let pingOutbounds: [[String: Any]] = try XCTUnwrap(pingConfig["outbounds"] as? [[String: Any]])
        XCTAssertEqual(pingOutbounds.count, 2)
    }


    func testLinkFragmentIsIgnoredWhenFromLinkIsOff() throws {
        let linked: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: XrayConfigBuilderTests.linkBase + "1-10,5-20,tlshello",
            tag: "t"
        )
        let plain: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentFromLink = false
        let expected: String = try XrayConfigBuilder.build(server: plain, inbounds: XrayConfigBuilderTests.inbounds)
        let actual: String = try XrayConfigBuilder.build(server: linked, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        XCTAssertEqual(try XrayConfigBuilderTests.canonical(actual), try XrayConfigBuilderTests.canonical(expected))
    }


    func testGlobalModeWinsOverTheLinkFragment() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: XrayConfigBuilderTests.linkBase + "1-10,5-20,tlshello",
            tag: "t"
        )
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "finalmask"
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        )
        let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 1)
        let stream: [String: Any] = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        XCTAssertNotNil(stream["finalmask"])
    }


    func testInvalidLinkFragmentIsIgnored() throws {
        let values: [String] = ["abc", "1-10,5-20", "10-1,5-20,tlshello", "1-10,x,tlshello", "1-10,5-20,nope", ""]
        for value: String in values {
            let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
                stream: #"{"network":"tcp"}"#,
                flow: nil,
                shareLink: XrayConfigBuilderTests.linkBase + value,
                tag: "t"
            )
            let config: [String: Any] = try XrayConfigBuilderTests.parse(
                try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: ImpulseProxyState.Advanced())
            )
            let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
            XCTAssertEqual(outbounds.count, 1, "value: \(value)")
        }
    }


    func testPingConfigCarriesTheSameTransformations() throws {
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "classic"
        advanced.fingerprint = "edge"
        advanced.muxEnabled = true
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp","security":"tls","tlsSettings":{}}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let config: [String: Any] = try XrayConfigBuilderTests.parse(
            try XrayConfigBuilder.pingConfig(server: server, advanced: advanced)
        )
        let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 2)
        XCTAssertNil(config["inbounds"])
        XCTAssertEqual(try XrayConfigBuilderTests.sockopt(outbounds[0])["dialerProxy"] as? String, "fragment")
        let stream: [String: Any] = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        let tlsSettings: [String: Any] = try XCTUnwrap(stream["tlsSettings"] as? [String: Any])
        XCTAssertEqual(tlsSettings["fingerprint"] as? String, "edge")
        let mux: [String: Any] = try XCTUnwrap(outbounds[0]["mux"] as? [String: Any])
        XCTAssertEqual(mux["enabled"] as? Bool, true)
    }


    func testStoredOutboundIsNotMutated() throws {
        let server: ImpulseProxyState.Server = try XrayConfigBuilderTests.makeServer(
            stream: #"{"network":"tcp"}"#,
            flow: nil,
            shareLink: nil,
            tag: "t"
        )
        let before: String = server.outboundJson
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.fragmentMode = "classic"
        advanced.muxEnabled = true
        advanced.fingerprint = "chrome"
        _ = try XrayConfigBuilder.build(server: server, inbounds: XrayConfigBuilderTests.inbounds, advanced: advanced)
        XCTAssertEqual(server.outboundJson, before)
    }


    private static func outboundJson(
        stream: String,
        flow: String?,
        tag: String
    ) -> String {
        var user: String = #"{"id":"11111111-1111-1111-1111-111111111111","encryption":"none""#
        if let flowValue: String = flow {
            user += #","flow":"\#(flowValue)""#
        }
        user += "}"
        return #"{"protocol":"vless","tag":"\#(tag)","settings":{"vnext":[{"address":"h.example","port":443,"users":[\#(user)]}]},"streamSettings":\#(stream)}"#
    }


    private static func makeServer(
        stream: String,
        flow: String?,
        shareLink: String?,
        tag: String
    ) throws -> ImpulseProxyState.Server {
        let json: String = outboundJson(stream: stream, flow: flow, tag: tag)
        var server: ImpulseProxyState.Server = try XCTUnwrap(ProxyOutboundFilter.makeServer(outboundJson: json))
        server.shareLink = shareLink
        return server
    }


    private static func goldenBuild(
        outbound: String
    ) -> String {
        return #"""
        {"log":{"loglevel":"error","access":"none"},"inbounds":[{"tag":"http-in","listen":"127.0.0.1","port":41001,"protocol":"http","settings":{"accounts":[{"user":"u","pass":"p"}],"allowTransparent":false}},{"tag":"socks-in","listen":"127.0.0.1","port":41002,"protocol":"socks","settings":{"auth":"password","accounts":[{"user":"u","pass":"p"}],"udp":true,"ip":"127.0.0.1"}}],"outbounds":[\#(outbound)],"routing":{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["http-in","socks-in"],"outboundTag":"proxy"}]}}
        """#
    }


    private static func parse(
        _ json: String
    ) throws -> [String: Any] {
        let parsed: Any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try XCTUnwrap(parsed as? [String: Any])
    }


    private static func jsonText(
        _ object: [String: Any]
    ) throws -> String {
        let data: Data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }


    /// Re-serializes JSON with sorted keys, so two documents compare regardless of key order and whitespace.
    private static func canonical(
        _ json: String
    ) throws -> String {
        let parsed: Any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let data: Data = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }


    private static func outbound(
        _ config: [String: Any],
        _ index: Int
    ) throws -> [String: Any] {
        let outbounds: [[String: Any]] = try XCTUnwrap(config["outbounds"] as? [[String: Any]])
        return outbounds[index]
    }


    private static func sockopt(
        _ outbound: [String: Any]
    ) throws -> [String: Any] {
        let stream: [String: Any] = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
        return try XCTUnwrap(stream["sockopt"] as? [String: Any])
    }
}
