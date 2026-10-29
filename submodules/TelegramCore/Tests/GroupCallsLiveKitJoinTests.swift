import XCTest
@testable import TelegramCore

final class GroupCallsLiveKitJoinTests: XCTestCase {
    private let validJSON: String = "{\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":\"t0ken\",\"room\":\"g.42\"}}"

    func testValidGroupParamsAreParsed() {
        let parsed: GroupCallLiveKitJoinParameters? = GroupCallLiveKitJoinParser.parse(json: validJSON, callId: 42)

        XCTAssertEqual(parsed, GroupCallLiveKitJoinParameters(url: "wss://lk.example.org", room: "g.42"))
    }

    func testPlainWsSchemeIsAccepted() {
        let json: String = "{\"livekit\":{\"url\":\"ws://lk.example.org:7880\",\"token\":\"t\",\"room\":\"g.42\"}}"

        XCTAssertNotNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testPeerRoomIsRejectedForGroupCall() {
        let json: String = "{\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":\"t\",\"room\":\"p.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testRoomOfAnotherCallIsRejected() {
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: validJSON, callId: 43))
    }

    func testNonPositiveCallIdIsRejected() {
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: validJSON, callId: 0))
    }

    func testMissingTokenIsRejected() {
        let json: String = "{\"livekit\":{\"url\":\"wss://lk.example.org\",\"room\":\"g.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testBlankTokenIsRejected() {
        let json: String = "{\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":\"  \",\"room\":\"g.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testNonStringFieldIsRejected() {
        let json: String = "{\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":1,\"room\":\"g.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testTgcallsShapedParamsAreRejected() {
        let json: String = "{\"ssrc\":12345,\"ssrc-groups\":[]}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: json, callId: 42))
    }

    func testNonObjectJSONIsRejected() {
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: "[1,2,3]", callId: 42))
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: "not json", callId: 42))
    }

    func testUnsafeURLsAreRejected() {
        let httpJSON: String = "{\"livekit\":{\"url\":\"https://lk.example.org\",\"token\":\"t\",\"room\":\"g.42\"}}"
        let userinfoJSON: String = "{\"livekit\":{\"url\":\"wss://user:pw@lk.example.org\",\"token\":\"t\",\"room\":\"g.42\"}}"
        let fragmentJSON: String = "{\"livekit\":{\"url\":\"wss://lk.example.org#x\",\"token\":\"t\",\"room\":\"g.42\"}}"
        let spaceJSON: String = "{\"livekit\":{\"url\":\"wss://lk example.org\",\"token\":\"t\",\"room\":\"g.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: httpJSON, callId: 42))
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: userinfoJSON, callId: 42))
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: fragmentJSON, callId: 42))
        XCTAssertNil(GroupCallLiveKitJoinParser.parse(json: spaceJSON, callId: 42))
    }

    func testMainJoinReturnsValidatedLiveKitJSONUnchanged() {
        XCTAssertEqual(GroupCallLiveKitJoinParser.mainJoinParams(json: validJSON, callId: 42), validJSON)
    }

    func testMainJoinRefusesBroadcastAnswer() {
        let json: String = "{\"stream\":true,\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":\"t\",\"room\":\"g.42\"}}"

        XCTAssertNil(GroupCallLiveKitJoinParser.mainJoinParams(json: json, callId: 42))
    }

    func testMainJoinRefusesRtmpBroadcastAnswer() {
        let json: String = "{\"stream\":true,\"rtmp\":true}"

        XCTAssertNil(GroupCallLiveKitJoinParser.mainJoinParams(json: json, callId: 42))
    }

    func testMainJoinRefusesTgcallsShapedAnswer() {
        let json: String = "{\"ssrc\":12345,\"ssrc-groups\":[]}"

        XCTAssertNil(GroupCallLiveKitJoinParser.mainJoinParams(json: json, callId: 42))
    }

    func testMainJoinRefusesInvalidLiveKitAnswer() {
        XCTAssertNil(GroupCallLiveKitJoinParser.mainJoinParams(json: validJSON, callId: 43))
        XCTAssertNil(GroupCallLiveKitJoinParser.mainJoinParams(json: "not json", callId: 42))
    }

    func testMainJoinAcceptsStreamFlagFalse() {
        let json: String = "{\"stream\":false,\"livekit\":{\"url\":\"wss://lk.example.org\",\"token\":\"t\",\"room\":\"g.42\"}}"

        XCTAssertEqual(GroupCallLiveKitJoinParser.mainJoinParams(json: json, callId: 42), json)
    }
}
