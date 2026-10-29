import XCTest
import LiveKit
@testable import TelegramVoip


/// A device with the identifier shape of `AudioDevice`, for the lookup tests.
private struct FakeMediaDevice: Identifiable {
    let id: String
}


final class LiveKitRoomMediaSDKTests: XCTestCase {
    func testNoiseFlagReachesCaptureOptions() {
        XCTAssertTrue(LiveKitRoomMediaSDK.audioCaptureOptions(noiseSuppression: true).noiseSuppression)
        XCTAssertFalse(LiveKitRoomMediaSDK.audioCaptureOptions(noiseSuppression: false).noiseSuppression)
    }


    func testNoiseFlagReachesProcessingOptions() {
        XCTAssertTrue(LiveKitRoomMediaSDK.audioProcessingOptions(noiseSuppression: true).noiseSuppression)
        XCTAssertFalse(LiveKitRoomMediaSDK.audioProcessingOptions(noiseSuppression: false).noiseSuppression)
    }


    func testOtherProcessingComponentsKeepSdkDefaults() {
        let options: AudioProcessingOptions = LiveKitRoomMediaSDK.audioProcessingOptions(noiseSuppression: false)

        XCTAssertEqual(options.echoCancellation, AudioCaptureOptions.defaultEchoCancellation)
        XCTAssertEqual(options.autoGainControl, AudioCaptureOptions.defaultAutoGainControl)
        XCTAssertFalse(options.highpassFilter)
    }


    func testDeviceLookupFindsTheDeviceWithTheIdentifier() {
        let devices: [FakeMediaDevice] = [FakeMediaDevice(id: "input-1"), FakeMediaDevice(id: "input-2")]

        let device: FakeMediaDevice? = LiveKitRoomMediaSDK.selectDevice(id: "input-2", in: devices)

        XCTAssertEqual(device?.id, "input-2")
    }


    func testUnknownDeviceIdSelectsNothing() {
        let devices: [FakeMediaDevice] = [FakeMediaDevice(id: "input-1")]

        let device: FakeMediaDevice? = LiveKitRoomMediaSDK.selectDevice(id: "missing", in: devices)

        XCTAssertNil(device)
    }


    func testEmptyDeviceListSelectsNothing() {
        let devices: [FakeMediaDevice] = []

        let device: FakeMediaDevice? = LiveKitRoomMediaSDK.selectDevice(id: "input-1", in: devices)

        XCTAssertNil(device)
    }


    func testScreenSharePublishHasNoSimulcastInGroupCall() {
        let options: VideoPublishOptions = LiveKitVideoSources.videoPublishOptions(captureCode: .screen, isGroupCall: true)

        XCTAssertFalse(options.simulcast)
    }
}
