import XCTest
import LiveKit
@testable import TelegramVoip


/// One media call recorded by `FakeLiveKitRoomMedia`.
enum FakeLiveKitRoomMediaCall: Equatable {
    case setMicrophoneEnabled(Bool)
    case setNoiseSuppressionEnabled(Bool)
    case setCameraEnabled(Bool)
    case publishCamera
    case publishScreenShare
    case unpublishScreenShare
    case setAudioInputDevice(String)
    case setAudioOutputDevice(String)
}


/// A local video track with no SDK track behind it.
final class FakeLiveKitLocalVideoTrack: LiveKitLocalVideoTrack {
    var sdkTrack: LocalVideoTrack? {
        return nil
    }
}


/// Records every media call in order. A call throws `errorToThrow` when it is set, and a throwing call records nothing.
final class FakeLiveKitRoomMedia: LiveKitRoomMedia {
    var errorToThrow: Error?
    private(set) var calls: [FakeLiveKitRoomMediaCall] = []


    func setMicrophoneEnabled(_ isEnabled: Bool) async throws {
        try throwIfNeeded()
        calls.append(.setMicrophoneEnabled(isEnabled))
    }


    func setNoiseSuppressionEnabled(_ isEnabled: Bool) async throws {
        try throwIfNeeded()
        calls.append(.setNoiseSuppressionEnabled(isEnabled))
    }


    func setCameraEnabled(_ isEnabled: Bool) async throws {
        try throwIfNeeded()
        calls.append(.setCameraEnabled(isEnabled))
    }


    func publishCamera(_ track: LiveKitLocalVideoTrack) async throws {
        try throwIfNeeded()
        calls.append(.publishCamera)
    }


    func publishScreenShare(_ track: LiveKitLocalVideoTrack) async throws {
        try throwIfNeeded()
        calls.append(.publishScreenShare)
    }


    func unpublishScreenShare() async throws {
        try throwIfNeeded()
        calls.append(.unpublishScreenShare)
    }


    func setAudioInputDevice(id: String) async throws {
        try throwIfNeeded()
        calls.append(.setAudioInputDevice(id))
    }


    func setAudioOutputDevice(id: String) async throws {
        try throwIfNeeded()
        calls.append(.setAudioOutputDevice(id))
    }


    private func throwIfNeeded() throws {
        if let error: Error = errorToThrow {
            throw error
        }
    }
}


private struct FakeMediaFailure: Error {}


final class LiveKitRoomMediaTests: XCTestCase {
    func testMicrophoneAndCameraCallsRecordTheirFlags() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()

        try await media.setMicrophoneEnabled(true)
        try await media.setMicrophoneEnabled(false)
        try await media.setCameraEnabled(true)

        XCTAssertEqual(
            media.calls,
            [
                .setMicrophoneEnabled(true),
                .setMicrophoneEnabled(false),
                .setCameraEnabled(true)
            ]
        )
    }


    func testNoiseSuppressionCallRecordsItsFlag() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()

        try await media.setNoiseSuppressionEnabled(true)

        XCTAssertEqual(media.calls, [.setNoiseSuppressionEnabled(true)])
    }


    func testScreenShareIsPublishedAndUnpublishedInOrder() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        let track: FakeLiveKitLocalVideoTrack = FakeLiveKitLocalVideoTrack()

        try await media.publishScreenShare(track)
        try await media.unpublishScreenShare()

        XCTAssertEqual(media.calls, [.publishScreenShare, .unpublishScreenShare])
    }


    func testDeviceCallsCarryTheDeviceIdentifier() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()

        try await media.setAudioInputDevice(id: "input-1")
        try await media.setAudioOutputDevice(id: "output-2")

        XCTAssertEqual(
            media.calls,
            [
                .setAudioInputDevice("input-1"),
                .setAudioOutputDevice("output-2")
            ]
        )
    }


    func testFakeTrackHasNoSdkTrack() {
        let track: FakeLiveKitLocalVideoTrack = FakeLiveKitLocalVideoTrack()

        XCTAssertNil(track.sdkTrack)
    }


    func testFailingCallThrowsAndRecordsNothing() async throws {
        let media: FakeLiveKitRoomMedia = FakeLiveKitRoomMedia()
        media.errorToThrow = FakeMediaFailure()

        do {
            try await media.setCameraEnabled(true)
            XCTFail("The call must throw")
        } catch {
            XCTAssertTrue(error is FakeMediaFailure)
        }

        XCTAssertEqual(media.calls, [])
    }
}
