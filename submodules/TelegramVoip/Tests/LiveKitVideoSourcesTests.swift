import XCTest
import LiveKit
@testable import TelegramVoip


final class LiveKitVideoSourcesTests: XCTestCase {
    func testCaptureCodesMatchAndroid() {
        XCTAssertEqual(LiveKitCaptureCode.back.rawValue, 0)
        XCTAssertEqual(LiveKitCaptureCode.front.rawValue, 1)
        XCTAssertEqual(LiveKitCaptureCode.screen.rawValue, 2)
    }


    func testScreenCodeCreatesNoCameraTrack() async {
        let track: LocalVideoTrack? = await LiveKitVideoSources.createCameraTrack(captureCode: .screen, deviceId: "")
        XCTAssertNil(track)
    }


    func testGroupCameraUsesSimulcast() {
        XCTAssertTrue(LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: true).simulcast)
        XCTAssertTrue(LiveKitVideoSources.videoPublishOptions(captureCode: .front, isGroupCall: true).simulcast)
    }


    func testOneToOneCameraHasNoSimulcast() {
        XCTAssertFalse(LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: false).simulcast)
        XCTAssertFalse(LiveKitVideoSources.videoPublishOptions(captureCode: .front, isGroupCall: false).simulcast)
    }


    func testScreenShareNeverUsesSimulcast() {
        XCTAssertFalse(LiveKitVideoSources.videoPublishOptions(captureCode: .screen, isGroupCall: true).simulcast)
        XCTAssertFalse(LiveKitVideoSources.videoPublishOptions(captureCode: .screen, isGroupCall: false).simulcast)
    }


    func testPrioritizeVP8SetsThePreferredCodec() {
        XCTAssertEqual(LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: true, prioritizeVP8: true).preferredCodec?.name, "vp8")
        XCTAssertNil(LiveKitVideoSources.videoPublishOptions(captureCode: .back, isGroupCall: true).preferredCodec)
    }
}
