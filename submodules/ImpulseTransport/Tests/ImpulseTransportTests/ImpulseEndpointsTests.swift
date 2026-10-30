import XCTest
@testable import ImpulseTransport

final class ImpulseEndpointsTests: XCTestCase {
    private let rpcBaseUrl: String = "https://rpc.example.org"

    func testConfiguredRealtimeUrl() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: self.rpcBaseUrl)

        XCTAssertEqual(
            endpoints.realtimeUrl(),
            "wss://rpc.example.org/connection/websocket?cf_ws_frame_ping_pong=true"
        )
    }

    func testConfiguredPoolUrl() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: self.rpcBaseUrl)

        XCTAssertEqual(
            endpoints.poolUrl(),
            "wss://rpc.example.org/pool/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testHttpsBaseWithDefaultPortOmitsPort() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: "https://rpc.example.test:443")

        XCTAssertEqual(
            endpoints.realtimeUrl(),
            "wss://rpc.example.test/connection/websocket?cf_ws_frame_ping_pong=true"
        )
    }

    func testHttpsBaseKeepsNonDefaultPort() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: "https://rpc.example.test:8443")

        XCTAssertEqual(
            endpoints.realtimeUrl(),
            "wss://rpc.example.test:8443/connection/websocket?cf_ws_frame_ping_pong=true"
        )
        XCTAssertEqual(
            endpoints.poolUrl(),
            "wss://rpc.example.test:8443/pool/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testHttpBaseSwapsToWsAndDefaultPortIsEighty() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: "http://localhost")

        XCTAssertEqual(
            endpoints.realtimeUrl(),
            "ws://localhost/connection/websocket?cf_ws_frame_ping_pong=true"
        )
    }

    func testHttpBaseKeepsNonDefaultPort() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: "http://localhost:8080")

        XCTAssertEqual(
            endpoints.poolUrl(),
            "ws://localhost:8080/pool/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testRpcBaseUrlIsKept() throws {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: self.rpcBaseUrl)

        XCTAssertEqual(endpoints.rpcBaseUrl.absoluteString, "https://rpc.example.org")
    }

    func testUnsupportedSchemeIsRejected() {
        XCTAssertThrowsError(try ImpulseEndpoints(baseUrl: "wss://rpc.example.org")) { (error: Error) in
            XCTAssertEqual(error as? ImpulseEndpointsError, .invalidBaseUrl("wss://rpc.example.org"))
        }
    }

    func testMissingHostIsRejected() {
        XCTAssertThrowsError(try ImpulseEndpoints(baseUrl: "https://")) { (error: Error) in
            XCTAssertEqual(error as? ImpulseEndpointsError, .invalidBaseUrl("https://"))
        }
    }

    func testEmptyBaseIsRejected() {
        XCTAssertThrowsError(try ImpulseEndpoints(baseUrl: ""))
    }

    func testMediaUrlFromIpv4MediaOnlyOption() {
        let dcOptions: [ImpulseDcOption] = [
            ImpulseDcOption(
                id: 2,
                ipAddress: "91.108.56.1",
                port: 443,
                ipv6: false,
                mediaOnly: true
            ),
        ]

        XCTAssertEqual(
            ImpulseEndpoints.mediaUrl(dcOptions: dcOptions, thisDc: 2),
            "wss://91.108.56.1:443/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testMediaUrlFromIpv6MediaOnlyOptionIsBracketed() {
        let dcOptions: [ImpulseDcOption] = [
            ImpulseDcOption(
                id: 2,
                ipAddress: "2001:db8::1",
                port: 8443,
                ipv6: true,
                mediaOnly: true
            ),
        ]

        XCTAssertEqual(
            ImpulseEndpoints.mediaUrl(dcOptions: dcOptions, thisDc: 2),
            "wss://[2001:db8::1]:8443/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testMediaUrlUsesOptionOfThisDcOnly() {
        let dcOptions: [ImpulseDcOption] = [
            ImpulseDcOption(
                id: 1,
                ipAddress: "10.0.0.1",
                port: 443,
                ipv6: false,
                mediaOnly: true
            ),
            ImpulseDcOption(
                id: 3,
                ipAddress: "10.0.0.3",
                port: 443,
                ipv6: false,
                mediaOnly: true
            ),
        ]

        XCTAssertEqual(
            ImpulseEndpoints.mediaUrl(dcOptions: dcOptions, thisDc: 3),
            "wss://10.0.0.3:443/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"
        )
    }

    func testMediaUrlIsNilWithoutMediaOnlyOptionForThisDc() {
        let dcOptions: [ImpulseDcOption] = [
            ImpulseDcOption(
                id: 2,
                ipAddress: "10.0.0.2",
                port: 443,
                ipv6: false,
                mediaOnly: false
            ),
            ImpulseDcOption(
                id: 4,
                ipAddress: "10.0.0.4",
                port: 443,
                ipv6: false,
                mediaOnly: true
            ),
        ]

        XCTAssertNil(ImpulseEndpoints.mediaUrl(dcOptions: dcOptions, thisDc: 2))
        XCTAssertNil(ImpulseEndpoints.mediaUrl(dcOptions: [], thisDc: 2))
    }
}
