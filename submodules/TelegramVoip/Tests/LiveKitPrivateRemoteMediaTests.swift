import XCTest
import LiveKit
@testable import TelegramVoip


/// A remote video track with no SDK track behind it. The chosen publication is what the tests compare.
private final class FakePrivateRemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    var sdkTrack: RemoteVideoTrack? {
        return nil
    }
}


/// A remote video publication with a fixed source, mute state and track.
private final class FakePrivateRemotePublication: LiveKitGroupRemotePublication {
    let videoTrack: LiveKitGroupRemoteVideoTrack?
    let source: LiveKitRemoteVideoSource
    let isMuted: Bool


    init(
        videoTrack: LiveKitGroupRemoteVideoTrack?,
        source: LiveKitRemoteVideoSource,
        isMuted: Bool = false
    ) {
        self.videoTrack = videoTrack
        self.source = source
        self.isMuted = isMuted
    }


    func setEnabled(_ isEnabled: Bool) async throws {
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
    }
}


/// A remote participant with fixed publications and audio activity.
private final class FakePrivateRemoteParticipant: LiveKitGroupRemoteParticipant {
    let identity: String?
    let videoPublications: [LiveKitGroupRemotePublication]
    let isAudioActive: Bool


    init(
        identity: String?,
        videoPublications: [LiveKitGroupRemotePublication],
        isAudioActive: Bool
    ) {
        self.identity = identity
        self.videoPublications = videoPublications
        self.isAudioActive = isAudioActive
    }
}


final class LiveKitPrivateRemoteMediaTests: XCTestCase {
    func testScreenShareWinsOverCamera() {
        let camera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)
        let screen: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .screenShare)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [camera], isAudioActive: false),
            FakePrivateRemoteParticipant(identity: "u1.2", videoPublications: [screen], isAudioActive: false)
        ])

        XCTAssertTrue(media.isVideoActive)
        XCTAssertTrue(media.publication === screen)
    }


    func testCameraWinsOverOtherWhenNoScreenShareExists() {
        let other: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .other)
        let camera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [other, camera], isAudioActive: false)
        ])

        XCTAssertTrue(media.publication === camera)
    }


    func testOtherIsChosenWhenItIsTheOnlyVideo() {
        let other: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .other)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [other], isAudioActive: false)
        ])

        XCTAssertTrue(media.publication === other)
    }


    func testFirstCandidateOfTheSameSourceWins() {
        let firstCamera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)
        let secondCamera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [firstCamera], isAudioActive: false),
            FakePrivateRemoteParticipant(identity: "u2.1", videoPublications: [secondCamera], isAudioActive: false)
        ])

        XCTAssertTrue(media.publication === firstCamera)
    }


    func testMutedScreenShareIsSkipped() {
        let mutedScreen: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .screenShare, isMuted: true)
        let camera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [mutedScreen, camera], isAudioActive: false)
        ])

        XCTAssertTrue(media.publication === camera)
    }


    func testTracklessScreenShareIsSkipped() {
        let tracklessScreen: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: nil, source: .screenShare)
        let camera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [tracklessScreen, camera], isAudioActive: false)
        ])

        XCTAssertTrue(media.publication === camera)
    }


    func testOnlyMutedOrTracklessPublicationsGiveNoVideo() {
        let mutedCamera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera, isMuted: true)
        let tracklessScreen: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: nil, source: .screenShare)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [mutedCamera, tracklessScreen], isAudioActive: false)
        ])

        XCTAssertFalse(media.isVideoActive)
        XCTAssertNil(media.publication)
        XCTAssertNil(media.videoTrack)
    }


    func testNoParticipantsGivesNoneWithoutAudio() {
        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([])

        XCTAssertFalse(media.isVideoActive)
        XCTAssertFalse(media.isAudioActive)
        XCTAssertNil(media.publication)
    }


    func testNoneHasNoVideoAndNoAudio() {
        XCTAssertFalse(LiveKitPrivateRemoteMedia.none.isVideoActive)
        XCTAssertFalse(LiveKitPrivateRemoteMedia.none.isAudioActive)
        XCTAssertNil(LiveKitPrivateRemoteMedia.none.publication)
    }


    func testAudioIsActiveWhenAnyParticipantHasActiveAudio() {
        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [], isAudioActive: false),
            FakePrivateRemoteParticipant(identity: "u2.1", videoPublications: [], isAudioActive: true)
        ])

        XCTAssertTrue(media.isAudioActive)
        XCTAssertFalse(media.isVideoActive)
    }


    func testAudioIsInactiveWhenNoParticipantHasActiveAudio() {
        let camera: FakePrivateRemotePublication = FakePrivateRemotePublication(videoTrack: FakePrivateRemoteVideoTrack(), source: .camera)

        let media: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia.resolve([
            FakePrivateRemoteParticipant(identity: "u1.1", videoPublications: [camera], isAudioActive: false)
        ])

        XCTAssertFalse(media.isAudioActive)
        XCTAssertTrue(media.isVideoActive)
    }
}
