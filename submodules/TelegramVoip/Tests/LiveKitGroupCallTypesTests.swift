import XCTest
@testable import TelegramVoip


final class LiveKitGroupCallTypesTests: XCTestCase {
    func testValidIdentityVectorsParse() throws {
        let userIdentity: LiveKitGroupIdentity = try LiveKitGroupIdentity.parse(identity: "u42.5")
        XCTAssertEqual(userIdentity, LiveKitGroupIdentity(kind: .user, peerId: 42, source: 5, isPresentation: false))

        let chatIdentity: LiveKitGroupIdentity = try LiveKitGroupIdentity.parse(identity: "c7.123456789")
        XCTAssertEqual(chatIdentity, LiveKitGroupIdentity(kind: .chat, peerId: 7, source: 123456789, isPresentation: false))

        let channelIdentity: LiveKitGroupIdentity = try LiveKitGroupIdentity.parse(identity: "h9.4294967295")
        XCTAssertEqual(channelIdentity, LiveKitGroupIdentity(kind: .channel, peerId: 9, source: 4294967295, isPresentation: false))
    }


    func testPresentationIdentityReportsPresentation() throws {
        let identity: LiveKitGroupIdentity = try LiveKitGroupIdentity.parse(identity: "u42.5.p")
        XCTAssertEqual(identity, LiveKitGroupIdentity(kind: .user, peerId: 42, source: 5, isPresentation: true))
        XCTAssertTrue(identity.isPresentation)
    }


    func testInvalidIdentityVectorsAreRejected() {
        let invalidIdentities: [String] = [
            "u42",
            "u42.0",
            "u042.5",
            "x42.5",
            "u42.-1",
            "u42.4294967296",
            "u42.5.q",
            "u42.5.p.p",
            "",
        ]
        for identity: String in invalidIdentities {
            XCTAssertThrowsError(try LiveKitGroupIdentity.parse(identity: identity), identity)
        }
    }


    func testSourceZeroAndSourceAboveUInt32AreRejected() {
        XCTAssertThrowsError(try LiveKitGroupIdentity.parse(identity: "c7.0"))
        XCTAssertThrowsError(try LiveKitGroupIdentity.parse(identity: "c7.4294967296"))
    }


    func testMaximumSourceIsAcceptedAsUnsignedBits() throws {
        let identity: LiveKitGroupIdentity = try LiveKitGroupIdentity.parse(identity: "u1.4294967295")
        XCTAssertEqual(identity.source, UInt32.max)
    }


    func testConnectedStateIsConnected() {
        let networkState: LiveKitGroupNetworkState = LiveKitGroupNetworkState(state: .connected)
        XCTAssertEqual(networkState, LiveKitGroupNetworkState(isConnected: true, isTransitioningFromBroadcastToRtc: false, isBroadcast: false))
    }


    func testConnectingAndEndedStatesAreNotConnected() {
        let connecting: LiveKitGroupNetworkState = LiveKitGroupNetworkState(state: .connecting)
        XCTAssertFalse(connecting.isConnected)
        XCTAssertFalse(connecting.isTransitioningFromBroadcastToRtc)
        XCTAssertFalse(connecting.isBroadcast)

        let ended: LiveKitGroupNetworkState = LiveKitGroupNetworkState(state: .ended(.hungUp))
        XCTAssertFalse(ended.isConnected)
        XCTAssertFalse(ended.isTransitioningFromBroadcastToRtc)
        XCTAssertFalse(ended.isBroadcast)
    }


    func testAudioLevelKeysAreDistinct() {
        XCTAssertNotEqual(LiveKitGroupAudioLevelKey.local, LiveKitGroupAudioLevelKey.source(0))
        XCTAssertEqual(LiveKitGroupAudioLevelKey.source(5), LiveKitGroupAudioLevelKey.source(5))
        XCTAssertNotEqual(LiveKitGroupAudioLevelKey.source(5), LiveKitGroupAudioLevelKey.source(6))
    }
}
