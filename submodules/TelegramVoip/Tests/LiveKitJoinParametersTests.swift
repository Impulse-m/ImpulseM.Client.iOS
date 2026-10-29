import XCTest
@testable import TelegramVoip


private let testToken: String = "bearer-secret-token-value"
private let testUrl: String = "wss://project.livekit.cloud"


final class LiveKitJoinParametersTests: XCTestCase {
    private func joinJson(
        url: String = testUrl,
        token: String = testToken,
        room: String = "p.42"
    ) -> String {
        return "{\"livekit\":{\"url\":\"\(url)\",\"token\":\"\(token)\",\"room\":\"\(room)\"}}"
    }


    private func assertParseFails(
        _ json: String,
        isGroup: Bool = false,
        callId: Int64 = 42,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LiveKitJoinParameters.parse(
                json: json,
                isGroup: isGroup,
                callId: callId
            ),
            file: file,
            line: line
        )
    }


    func testParsesValidOneToOneJoin() throws {
        let parameters: LiveKitJoinParameters = try LiveKitJoinParameters.parse(
            json: joinJson(),
            isGroup: false,
            callId: 42
        )
        XCTAssertEqual(parameters.url, testUrl)
        XCTAssertEqual(parameters.token, testToken)
        XCTAssertEqual(parameters.room, "p.42")
    }


    func testAcceptsWsScheme() throws {
        let parameters: LiveKitJoinParameters = try LiveKitJoinParameters.parse(
            json: joinJson(url: "ws://127.0.0.1:7880"),
            isGroup: false,
            callId: 42
        )
        XCTAssertEqual(parameters.url, "ws://127.0.0.1:7880")
    }


    func testGroupRoomUsesGPrefix() throws {
        let parameters: LiveKitJoinParameters = try LiveKitJoinParameters.parse(
            json: joinJson(room: "g.42"),
            isGroup: true,
            callId: 42
        )
        XCTAssertEqual(parameters.room, "g.42")
    }


    func testRejectsRoomMismatch() {
        assertParseFails(joinJson(room: "p.43"), callId: 42)
        assertParseFails(joinJson(room: "g.42"), isGroup: false, callId: 42)
        assertParseFails(joinJson(room: "p.42"), isGroup: true, callId: 42)
    }


    func testRejectsNonPositiveCallId() {
        assertParseFails(joinJson(room: "p.0"), callId: 0)
        assertParseFails(joinJson(room: "p.-1"), callId: -1)
    }


    func testRejectsNonWsSchemes() {
        assertParseFails(joinJson(url: "https://project.livekit.cloud"))
        assertParseFails(joinJson(url: "http://project.livekit.cloud"))
        assertParseFails(joinJson(url: "project.livekit.cloud"))
    }


    func testRejectsUserinfoFragmentAndMissingHost() {
        assertParseFails(joinJson(url: "wss://user:pass@project.livekit.cloud"))
        assertParseFails(joinJson(url: "wss://project.livekit.cloud/path#fragment"))
        assertParseFails(joinJson(url: "wss://"))
    }


    func testRejectsBlankAndSpacedUrl() {
        assertParseFails(joinJson(url: "   "))
        assertParseFails(joinJson(url: "wss://project livekit.cloud"))
    }


    func testRejectsBlankFields() {
        assertParseFails(joinJson(token: "   "))
        assertParseFails("{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\",\"room\":\"\"}}")
    }


    func testRejectsNonStringFields() {
        assertParseFails("{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":5,\"room\":\"p.42\"}}")
        assertParseFails("{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\",\"room\":true}}")
    }


    func testRejectsMissingFieldsAndWrongShape() {
        assertParseFails("{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\"}}")
        assertParseFails("{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\",\"room\":\"p.42\"}")
        assertParseFails("[\"livekit\"]")
        assertParseFails("not json")
        assertParseFails("")
    }


    func testErrorTextIsCanonicalAndHasNoToken() {
        XCTAssertThrowsError(
            try LiveKitJoinParameters.parse(
                json: joinJson(url: "https://project.livekit.cloud"),
                isGroup: false,
                callId: 42
            )
        ) { (error: Error) -> Void in
            XCTAssertEqual(error.localizedDescription, "Invalid LiveKit join parameters for this call")
            XCTAssertFalse(error.localizedDescription.contains(testToken))
        }
    }


    func testMalformedJsonErrorHasNoToken() {
        XCTAssertThrowsError(
            try LiveKitJoinParameters.parse(
                json: "{\"livekit\":{\"token\":\"\(testToken)\"",
                isGroup: false,
                callId: 42
            )
        ) { (error: Error) -> Void in
            XCTAssertFalse(String(describing: error).contains(testToken))
            XCTAssertFalse(error.localizedDescription.contains(testToken))
        }
    }


    func testDescriptionNeverPrintsToken() throws {
        let parameters: LiveKitJoinParameters = try LiveKitJoinParameters.parse(
            json: joinJson(),
            isGroup: false,
            callId: 42
        )
        XCTAssertFalse(String(describing: parameters).contains(testToken))
        XCTAssertFalse("\(parameters)".contains(testToken))
        XCTAssertFalse(String(reflecting: parameters).contains(testToken))
        XCTAssertTrue(String(describing: parameters).contains("<redacted>"))
    }


    func testGroupSourceVectorsValid() throws {
        XCTAssertEqual(try LiveKitIdentity.groupSource(identity: "u42.5"), 5)
        XCTAssertEqual(try LiveKitIdentity.groupSource(identity: "c7.123456789"), 123456789)
        XCTAssertEqual(try LiveKitIdentity.groupSource(identity: "h9.4294967295"), -1)
        XCTAssertEqual(try LiveKitIdentity.groupSource(identity: "u42.5.p"), 5)
    }


    func testGroupSourceVectorsInvalid() {
        let invalidIdentities: [String] = [
            "u42",
            "u42.0",
            "u042.5",
            "x42.5",
            "u42.-1",
            "u42.4294967296",
            "u42.5.q",
            "u42.5.",
            "u.5",
            "u42.5 ",
            "",
        ]
        for identity: String in invalidIdentities {
            XCTAssertThrowsError(try LiveKitIdentity.groupSource(identity: identity), identity)
        }
    }
}
