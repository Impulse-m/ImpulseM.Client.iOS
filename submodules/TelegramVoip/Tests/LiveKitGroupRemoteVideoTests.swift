import XCTest
import LiveKit
@testable import TelegramVoip


/// One call made on a fake publication.
private enum FakeRemotePublicationCall: Equatable {
    case setEnabled(Bool)
    case setVideoQuality(LiveKitGroupVideoQuality)
}


/// A remote video track with no SDK track behind it.
private final class FakeRemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    var sdkTrack: RemoteVideoTrack? {
        return nil
    }
}


/// Records every call made on it. A call throws `errorToThrow` when it is set, and a throwing call records nothing.
private final class FakeRemotePublication: LiveKitGroupRemotePublication {
    let videoTrack: LiveKitGroupRemoteVideoTrack?
    var errorToThrow: Error?
    private(set) var calls: [FakeRemotePublicationCall] = []


    init(videoTrack: LiveKitGroupRemoteVideoTrack?) {
        self.videoTrack = videoTrack
    }


    func setEnabled(_ isEnabled: Bool) async throws {
        if let error: Error = errorToThrow {
            throw error
        }
        calls.append(.setEnabled(isEnabled))
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
        if let error: Error = errorToThrow {
            throw error
        }
        calls.append(.setVideoQuality(quality))
    }
}


/// A remote participant with a fixed identity and fixed publications.
private final class FakeRemoteParticipant: LiveKitGroupRemoteParticipant {
    let identity: String?
    let videoPublications: [LiveKitGroupRemotePublication]


    init(
        identity: String?,
        videoPublications: [LiveKitGroupRemotePublication]
    ) {
        self.identity = identity
        self.videoPublications = videoPublications
    }
}


private struct FakeRemoteFailure: Error {}


final class LiveKitGroupRemoteVideoTests: XCTestCase {
    func testPresentationEndpointResolvesToItsTrack() {
        let track: FakeRemoteVideoTrack = FakeRemoteVideoTrack()
        let presentation: FakeRemotePublication = FakeRemotePublication(videoTrack: track)
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: "u42.5.p", videoPublications: [presentation])]
        })

        let resolved: LiveKitGroupRemoteVideoTrack? = remoteVideo.videoTrack(endpoint: "u42.5.p")

        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved === track)
    }


    func testCameraEndpointDoesNotResolveToPresentationParticipant() {
        let track: FakeRemoteVideoTrack = FakeRemoteVideoTrack()
        let presentation: FakeRemotePublication = FakeRemotePublication(videoTrack: track)
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: "u42.5.p", videoPublications: [presentation])]
        })

        XCTAssertNil(remoteVideo.videoTrack(endpoint: "u42.5"))
    }


    func testUnknownEndpointReturnsNil() {
        let track: FakeRemoteVideoTrack = FakeRemoteVideoTrack()
        let camera: FakeRemotePublication = FakeRemotePublication(videoTrack: track)
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: "c7.123", videoPublications: [camera])]
        })

        XCTAssertNil(remoteVideo.videoTrack(endpoint: "u99.1"))
    }


    func testParticipantWithoutVideoTrackReturnsNil() {
        let camera: FakeRemotePublication = FakeRemotePublication(videoTrack: nil)
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: "u42.5", videoPublications: [camera])]
        })

        XCTAssertNil(remoteVideo.videoTrack(endpoint: "u42.5"))
    }


    func testRequestDisablesAbsentEndpointsAndAppliesVisibleOnes() async throws {
        let cameraPublication: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let presentationPublication: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let otherPublication: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [
                FakeRemoteParticipant(identity: "u1.1", videoPublications: [cameraPublication]),
                FakeRemoteParticipant(identity: "u2.2.p", videoPublications: [presentationPublication]),
                FakeRemoteParticipant(identity: "u3.3", videoPublications: [otherPublication]),
            ]
        })

        try await remoteVideo.applyRequests([
            LiveKitGroupVideoRequest(endpoint: "u1.1", quality: .high, isVisible: true),
            LiveKitGroupVideoRequest(endpoint: "u2.2.p", quality: .low, isVisible: false),
        ])

        XCTAssertEqual(cameraPublication.calls, [.setEnabled(true), .setVideoQuality(.high)])
        XCTAssertEqual(presentationPublication.calls, [.setEnabled(false)])
        XCTAssertEqual(otherPublication.calls, [.setEnabled(false)])
    }


    func testRequestForUnknownEndpointLeavesRoomPublicationsDisabled() async throws {
        let cameraPublication: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: "u1.1", videoPublications: [cameraPublication])]
        })

        try await remoteVideo.applyRequests([
            LiveKitGroupVideoRequest(endpoint: "u9.9", quality: .medium, isVisible: true),
        ])

        XCTAssertEqual(cameraPublication.calls, [.setEnabled(false)])
    }


    func testParticipantWithoutIdentityIsNotTouched() async throws {
        let publication: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [FakeRemoteParticipant(identity: nil, videoPublications: [publication])]
        })

        try await remoteVideo.applyRequests([
            LiveKitGroupVideoRequest(endpoint: "u1.1", quality: .high, isVisible: true),
        ])

        XCTAssertEqual(publication.calls, [])
    }


    func testFailureOnOnePublicationStillAppliesTheOthersAndIsThrown() async {
        let failing: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        failing.errorToThrow = FakeRemoteFailure()
        let healthy: FakeRemotePublication = FakeRemotePublication(videoTrack: FakeRemoteVideoTrack())
        let remoteVideo: LiveKitGroupRemoteVideo = LiveKitGroupRemoteVideo(remoteParticipants: {
            return [
                FakeRemoteParticipant(identity: "u1.1", videoPublications: [failing]),
                FakeRemoteParticipant(identity: "u2.2", videoPublications: [healthy]),
            ]
        })

        do {
            try await remoteVideo.applyRequests([
                LiveKitGroupVideoRequest(endpoint: "u2.2", quality: .low, isVisible: true),
            ])
            XCTFail("The first failure must be thrown")
        } catch {
            XCTAssertTrue(error is FakeRemoteFailure)
        }

        XCTAssertEqual(healthy.calls, [.setEnabled(true), .setVideoQuality(.low)])
        XCTAssertEqual(failing.calls, [])
    }
}
