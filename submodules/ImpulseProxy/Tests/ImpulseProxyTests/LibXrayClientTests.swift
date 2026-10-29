import Foundation
import XCTest
@testable import ImpulseProxy


final class FakeLibXrayBridge: LibXrayBridge, @unchecked Sendable {
    private(set) var requests: [String] = []
    private(set) var maxInFlight: Int = 0
    private var inFlight: Int = 0
    private let response: String?


    init(
        response: String?
    ) {
        self.response = response
    }


    func invoke(
        requestJSON: String
    ) -> String? {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        requests.append(requestJSON)
        inFlight -= 1
        return response
    }
}


final class LibXrayClientTests: XCTestCase {
    private static let method: String = "convertShareLinksToXrayJson"
    // Xray refuses VLESS without TLS to a public address, so the link the real bridge converts carries TLS.
    private static let link: String = "vless://11111111-2222-3333-4444-555555555555@example.com:443?security=tls&sni=example.com&type=tcp#Test"


    func testEnvelopeCarriesVersionMethodAndPayload() throws {
        let bridge: FakeLibXrayBridge = FakeLibXrayBridge(response: "{\"success\":true,\"data\":{\"outbounds\":[]}}")
        let client: LibXrayClient = LibXrayClient(bridge: bridge)
        _ = try client.convertShareLinks(text: LibXrayClientTests.link)
        let request: [String: Any] = try decodeObject(try XCTUnwrap(bridge.requests.first))
        XCTAssertEqual(request["apiVersion"] as? Int, 3)
        XCTAssertEqual(request["method"] as? String, LibXrayClientTests.method)
        let payload: [String: Any] = try XCTUnwrap(request["payload"] as? [String: Any])
        XCTAssertEqual(payload["text"] as? String, LibXrayClientTests.link)
    }


    func testConvertReturnsOutboundJSON() throws {
        let response: String = "{\"success\":true,\"data\":{\"outbounds\":[{\"tag\":\"Test\",\"protocol\":\"vless\"}]}}"
        let client: LibXrayClient = LibXrayClient(bridge: FakeLibXrayBridge(response: response))
        let outbounds: [String] = try client.convertShareLinks(text: LibXrayClientTests.link)
        XCTAssertEqual(outbounds.count, 1)
        let outbound: [String: Any] = try decodeObject(try XCTUnwrap(outbounds.first))
        XCTAssertEqual(outbound["protocol"] as? String, "vless")
        XCTAssertEqual(outbound["tag"] as? String, "Test")
    }


    func testFailedResponseCarriesLibXrayMessage() {
        let client: LibXrayClient = LibXrayClient(bridge: FakeLibXrayBridge(response: "{\"success\":false,\"error\":\"bad link\"}"))
        XCTAssertThrowsError(try client.convertShareLinks(text: LibXrayClientTests.link)) { (error: Error) -> Void in
            XCTAssertEqual(
                error as? LibXrayError,
                LibXrayError.methodFailed(
                    method: LibXrayClientTests.method,
                    message: "bad link"
                )
            )
        }
    }


    func testFailedResponseWithoutTextUsesUnknownError() {
        let client: LibXrayClient = LibXrayClient(bridge: FakeLibXrayBridge(response: "{\"success\":false}"))
        XCTAssertThrowsError(try client.convertShareLinks(text: LibXrayClientTests.link)) { (error: Error) -> Void in
            XCTAssertEqual(
                error as? LibXrayError,
                LibXrayError.methodFailed(
                    method: LibXrayClientTests.method,
                    message: "unknown error"
                )
            )
        }
    }


    func testMissingResponseIsMalformed() {
        assertMalformed(response: nil)
    }


    func testNonObjectResponseIsMalformed() {
        assertMalformed(response: "[]")
    }


    func testNonBooleanSuccessIsMalformed() {
        assertMalformed(response: "{\"success\":1,\"data\":{\"outbounds\":[]}}")
    }


    func testMissingOutboundsIsMalformed() {
        assertMalformed(response: "{\"success\":true,\"data\":{}}")
    }


    func testOutboundsNotArrayIsMalformed() {
        assertMalformed(response: "{\"success\":true,\"data\":{\"outbounds\":{}}}")
    }


    func testOversizedResponseIsRejected() {
        let oversized: String = String(repeating: "a", count: LibXrayClient.maxResponseBytes + 1)
        let client: LibXrayClient = LibXrayClient(bridge: FakeLibXrayBridge(response: oversized))
        XCTAssertThrowsError(try client.convertShareLinks(text: LibXrayClientTests.link)) { (error: Error) -> Void in
            XCTAssertEqual(
                error as? LibXrayError,
                LibXrayError.responseTooLarge(method: LibXrayClientTests.method)
            )
        }
    }


    func testConcurrentCallsNeverOverlapInBridge() {
        let bridge: FakeLibXrayBridge = FakeLibXrayBridge(response: "{\"success\":true,\"data\":{\"outbounds\":[]}}")
        let client: LibXrayClient = LibXrayClient(bridge: bridge)
        DispatchQueue.concurrentPerform(iterations: 16) { (index: Int) -> Void in
            _ = try? client.convertShareLinks(text: LibXrayClientTests.link)
        }
        XCTAssertEqual(bridge.requests.count, 16)
        XCTAssertEqual(bridge.maxInFlight, 1)
    }


    func testCGoBridgeConvertsVlessLink() throws {
        let client: LibXrayClient = LibXrayClient(bridge: LibXrayCGoBridge())
        let outbounds: [String] = try client.convertShareLinks(text: LibXrayClientTests.link)
        XCTAssertEqual(outbounds.count, 1)
        let outbound: [String: Any] = try decodeObject(try XCTUnwrap(outbounds.first))
        XCTAssertEqual(outbound["protocol"] as? String, "vless")
    }


    private func assertMalformed(
        response: String?
    ) {
        let client: LibXrayClient = LibXrayClient(bridge: FakeLibXrayBridge(response: response))
        XCTAssertThrowsError(try client.convertShareLinks(text: LibXrayClientTests.link)) { (error: Error) -> Void in
            XCTAssertEqual(
                error as? LibXrayError,
                LibXrayError.malformedResponse(method: LibXrayClientTests.method)
            )
        }
    }


    private func decodeObject(
        _ text: String
    ) throws -> [String: Any] {
        let data: Data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
