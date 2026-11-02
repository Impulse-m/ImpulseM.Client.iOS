import XCTest
import LiveKit
@testable import TelegramVoip


private let testUrl: String = "wss://project.livekit.cloud"
private let testToken: String = "bearer-secret-token-value"
private let testCallId: Int64 = 42
private let testWaitAttempts: Int = 200
private let testWaitStepNanoseconds: UInt64 = 10_000_000
private let testQuietNanoseconds: UInt64 = 100_000_000


private enum FakePrivateFailure: Error {
    case failed
}


/// The media calls that the fake room records, in the order they were made.
private enum FakePrivateMediaCall: Equatable {
    case microphone(Bool)
    case publishCamera
    case unpublishCamera
    case publishScreenShare
    case unpublishScreenShare
    case audioInput(String)
    case audioOutput(String)
}


/// A remote video track with no SDK track behind it.
private final class FakeCallRemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    var sdkTrack: RemoteVideoTrack? {
        return nil
    }
}


/// A remote video publication with a fixed source, mute state and track.
private final class FakeCallRemotePublication: LiveKitGroupRemotePublication {
    let videoTrack: LiveKitGroupRemoteVideoTrack?
    let source: LiveKitRemoteVideoSource
    let isMuted: Bool


    init(
        videoTrack: LiveKitGroupRemoteVideoTrack?,
        source: LiveKitRemoteVideoSource
    ) {
        self.videoTrack = videoTrack
        self.source = source
        self.isMuted = false
    }


    func setEnabled(_ isEnabled: Bool) async throws {
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
    }
}


/// A remote participant with fixed publications and audio activity.
private final class FakeCallRemoteParticipant: LiveKitGroupRemoteParticipant {
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


/// A local camera or screen capturer. It hands out a fake track unless it is told to produce none.
private final class FakePrivateCapturer: LiveKitPrivateVideoCapturer {
    let videoKind: LiveKitPrivateVideoKind
    let producesTrack: Bool


    init(
        videoKind: LiveKitPrivateVideoKind,
        producesTrack: Bool = true
    ) {
        self.videoKind = videoKind
        self.producesTrack = producesTrack
    }


    @MainActor
    func makeLocalVideoTrack() async -> LiveKitLocalVideoTrack? {
        guard producesTrack else {
            return nil
        }
        return FakeLiveKitLocalVideoTrack()
    }
}


/// A finite fake room session. It records the media calls, and every publish throws once `failPublishing` is set.
private final class FakePrivateRoomSession: LiveKitCallRoomSession, @unchecked Sendable {
    var onAudioTrackAvailable: ((LiveKitAudioTrackHandle) -> Void)?
    var onAudioTrackRemoved: ((LiveKitAudioTrackHandle) -> Void)?
    private let lock: NSLock = NSLock()
    private var recordedCalls: [FakePrivateMediaCall] = []
    private var fakeRemoteParticipants: [LiveKitGroupRemoteParticipant] = []
    private var publishError: Error?


    var calls: [FakePrivateMediaCall] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recordedCalls
    }


    var remoteParticipants: [LiveKitGroupRemoteParticipant] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return fakeRemoteParticipants
    }


    func setRemoteParticipants(_ participants: [LiveKitGroupRemoteParticipant]) {
        lock.lock()
        fakeRemoteParticipants = participants
        lock.unlock()
    }


    func failPublishing(with error: Error) {
        lock.lock()
        publishError = error
        lock.unlock()
    }


    func connect(url: String, token: String) async throws {
    }


    func disconnect() async {
    }


    func setMicrophoneEnabled(_ isEnabled: Bool) async throws {
        record(.microphone(isEnabled))
    }


    func setNoiseSuppressionEnabled(_ isEnabled: Bool) async throws {
    }


    func setCameraEnabled(_ isEnabled: Bool) async throws {
    }


    func publishCamera(_ track: LiveKitLocalVideoTrack) async throws {
        try recordPublish(.publishCamera)
    }


    func unpublishCamera() async throws {
        record(.unpublishCamera)
    }


    func publishScreenShare(_ track: LiveKitLocalVideoTrack) async throws {
        try recordPublish(.publishScreenShare)
    }


    func unpublishScreenShare() async throws {
        record(.unpublishScreenShare)
    }


    func setAudioInputDevice(id: String) async throws {
        record(.audioInput(id))
    }


    func setAudioOutputDevice(id: String) async throws {
        record(.audioOutput(id))
    }


    private func record(_ call: FakePrivateMediaCall) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }


    private func recordPublish(_ call: FakePrivateMediaCall) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        if let error: Error = publishError {
            throw error
        }
        recordedCalls.append(call)
    }
}


private extension LiveKitPrivateCallSnapshot.Connection {
    var isConnected: Bool {
        switch self {
        case .connected:
            return true

        case .connecting, .ended:
            return false
        }
    }


    var endReason: LiveKitCallEndReason? {
        switch self {
        case .ended(let reason):
            return reason

        case .connecting, .connected:
            return nil
        }
    }
}


private func joinJson() -> String {
    return "{\"livekit\":{\"url\":\"\(testUrl)\",\"token\":\"\(testToken)\",\"room\":\"p.42\"}}"
}


private func authKey(length: Int) -> Data {
    return Data(repeating: 7, count: length)
}


@MainActor
private func makeContext(session: FakePrivateRoomSession) throws -> LiveKitCallContext {
    return try LiveKitCallContext(
        callId: testCallId,
        versions: [LiveKitCallContext.protocolName],
        parameters: joinJson(),
        authKey: authKey(length: 256),
        joinDeadline: 5,
        leaveDeadline: 5,
        makeSession: { _, _ in session }
    )
}


/// Polls the predicate for a bounded number of steps and reports whether it became true.
@MainActor
private func waitUntil(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<testWaitAttempts {
        if predicate() {
            return true
        }
        try? await Task.sleep(nanoseconds: testWaitStepNanoseconds)
    }
    return predicate()
}


@MainActor
final class LiveKitPrivateCallTests: XCTestCase {
    func testInitialSnapshotIsConnectingWithoutVideoAndWithAudioActive() throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)

        XCTAssertFalse(call.snapshot.connection.isConnected)
        XCTAssertNil(call.snapshot.connection.endReason)
        XCTAssertNil(call.snapshot.localVideo)
        XCTAssertFalse(call.snapshot.isRemoteVideoActive)
        XCTAssertTrue(call.snapshot.isRemoteAudioActive)
    }


    func testMicrophoneIsAppliedUnmutedOnConnect() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.start()
        let applied: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.microphone(true))
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(session.calls.first, FakePrivateMediaCall.microphone(true))
    }


    func testMutedBeforeConnectIsAppliedMutedOnConnect() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setMuted(true)
        call.start()
        let applied: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.microphone(false))
        }
        XCTAssertTrue(applied)
        XCTAssertEqual(session.calls.first, FakePrivateMediaCall.microphone(false))
    }


    func testDeviceChoicesMadeBeforeConnectAreAppliedInOrder() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setAudioInputDevice("input-1")
        call.setAudioOutputDevice("output-1")
        call.start()
        let applied: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.audioOutput("output-1"))
        }
        XCTAssertTrue(applied)
        let deviceCalls: [FakePrivateMediaCall] = session.calls.filter { (recorded: FakePrivateMediaCall) -> Bool in
            return recorded == FakePrivateMediaCall.audioInput("input-1") || recorded == FakePrivateMediaCall.audioOutput("output-1")
        }
        XCTAssertEqual(deviceCalls, [.audioInput("input-1"), .audioOutput("output-1")])
    }


    func testCameraIsPublishedOnConnectAfterUnpublishingScreenShare() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        call.start()
        let published: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(published)
        XCTAssertEqual(session.calls, [.microphone(true), .unpublishScreenShare, .publishCamera])
        XCTAssertEqual(call.snapshot.localVideo, .camera)
    }


    func testCameraToScreenUnpublishesCameraBeforePublishingScreen() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        call.start()
        let cameraPublished: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(cameraPublished)
        let mark: Int = session.calls.count
        call.setVideo(FakePrivateCapturer(videoKind: .screen))
        let screenPublished: Bool = await waitUntil { () -> Bool in
            return session.calls.count >= mark + 2
        }
        XCTAssertTrue(screenPublished)
        XCTAssertEqual(Array(session.calls.dropFirst(mark)), [.unpublishCamera, .publishScreenShare])
        XCTAssertEqual(call.snapshot.localVideo, .screen)
    }


    func testScreenToCameraUnpublishesScreenShareBeforePublishingCamera() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .screen))
        call.start()
        let screenPublished: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishScreenShare)
        }
        XCTAssertTrue(screenPublished)
        let mark: Int = session.calls.count
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        let cameraPublished: Bool = await waitUntil { () -> Bool in
            return session.calls.count >= mark + 2
        }
        XCTAssertTrue(cameraPublished)
        XCTAssertEqual(Array(session.calls.dropFirst(mark)), [.unpublishScreenShare, .publishCamera])
    }


    func testSetVideoNilUnpublishesBothKinds() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        call.start()
        let published: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(published)
        let mark: Int = session.calls.count
        call.setVideo(nil)
        XCTAssertNil(call.snapshot.localVideo)
        let unpublished: Bool = await waitUntil { () -> Bool in
            return session.calls.count >= mark + 2
        }
        XCTAssertTrue(unpublished)
        XCTAssertEqual(Array(session.calls.dropFirst(mark)), [.unpublishCamera, .unpublishScreenShare])
    }


    func testSameCapturerIsNotAppliedTwice() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        let capturer: FakePrivateCapturer = FakePrivateCapturer(videoKind: .camera)
        call.setVideo(capturer)
        call.start()
        let published: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(published)
        let mark: Int = session.calls.count
        call.setVideo(capturer)
        try await Task.sleep(nanoseconds: testQuietNanoseconds)
        XCTAssertEqual(session.calls.count, mark)
    }


    func testCapturerWithoutTrackSkipsThePublish() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .camera, producesTrack: false))
        call.start()
        let unpublished: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.unpublishScreenShare)
        }
        XCTAssertTrue(unpublished)
        try await Task.sleep(nanoseconds: testQuietNanoseconds)
        XCTAssertFalse(session.calls.contains(FakePrivateMediaCall.publishCamera))
    }


    func testSetVideoUpdatesLocalVideoAtOnce() throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        var emittedScreenCount: Int = 0
        call.onSnapshot = { (snapshot: LiveKitPrivateCallSnapshot) -> Void in
            if snapshot.localVideo == .screen {
                emittedScreenCount += 1
            }
        }
        call.setVideo(FakePrivateCapturer(videoKind: .screen))
        XCTAssertEqual(call.snapshot.localVideo, .screen)
        XCTAssertEqual(emittedScreenCount, 1)
    }


    func testPublishFailureEndsCallWithConnectionFailure() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        session.failPublishing(with: FakePrivateFailure.failed)
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.start()
        let connected: Bool = await waitUntil { () -> Bool in
            return call.snapshot.connection.isConnected
        }
        XCTAssertTrue(connected)
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        let ended: Bool = await waitUntil { () -> Bool in
            return call.snapshot.connection.endReason == .connectionFailed
        }
        XCTAssertTrue(ended)
    }


    func testRemoteVideoAndAudioFollowRemoteParticipantsOnConnectAndChange() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let camera: FakeCallRemotePublication = FakeCallRemotePublication(videoTrack: FakeCallRemoteVideoTrack(), source: .camera)
        session.setRemoteParticipants([
            FakeCallRemoteParticipant(identity: "u2.1", videoPublications: [camera], isAudioActive: true)
        ])
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.start()
        let remoteReady: Bool = await waitUntil { () -> Bool in
            return call.snapshot.isRemoteVideoActive
        }
        XCTAssertTrue(remoteReady)
        XCTAssertTrue(call.snapshot.isRemoteAudioActive)
        session.setRemoteParticipants([])
        context.roomRemoteTracksDidChange()
        XCTAssertFalse(call.snapshot.isRemoteVideoActive)
        XCTAssertFalse(call.snapshot.isRemoteAudioActive)
    }


    func testStopEndsCallAndClearsLocalAndRemoteVideo() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let camera: FakeCallRemotePublication = FakeCallRemotePublication(videoTrack: FakeCallRemoteVideoTrack(), source: .camera)
        session.setRemoteParticipants([
            FakeCallRemoteParticipant(identity: "u2.1", videoPublications: [camera], isAudioActive: true)
        ])
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        var remoteVideoCount: Int = 0
        call.onRemoteVideo = { (track: VideoTrack?) -> Void in
            remoteVideoCount += 1
        }
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        call.start()
        let remoteReady: Bool = await waitUntil { () -> Bool in
            return call.snapshot.isRemoteVideoActive && session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(remoteReady)
        XCTAssertEqual(call.snapshot.localVideo, .camera)
        XCTAssertTrue(call.snapshot.isRemoteAudioActive)
        call.stop()
        let ended: Bool = await waitUntil { () -> Bool in
            return call.snapshot.connection.endReason == .hungUp
        }
        XCTAssertTrue(ended)
        XCTAssertNil(call.snapshot.localVideo)
        XCTAssertFalse(call.snapshot.isRemoteVideoActive)
        XCTAssertFalse(call.snapshot.isRemoteAudioActive)
        XCTAssertEqual(remoteVideoCount, 1)
    }


    func testNothingIsAppliedAfterTheEnd() async throws {
        let session: FakePrivateRoomSession = FakePrivateRoomSession()
        let context: LiveKitCallContext = try makeContext(session: session)
        let call: LiveKitPrivateCall = LiveKitPrivateCall(context: context)
        call.setVideo(FakePrivateCapturer(videoKind: .camera))
        call.start()
        let published: Bool = await waitUntil { () -> Bool in
            return session.calls.contains(FakePrivateMediaCall.publishCamera)
        }
        XCTAssertTrue(published)
        call.stop()
        let ended: Bool = await waitUntil { () -> Bool in
            return call.snapshot.connection.endReason == .hungUp
        }
        XCTAssertTrue(ended)
        let mark: Int = session.calls.count
        call.setVideo(FakePrivateCapturer(videoKind: .screen))
        call.setMuted(true)
        call.setAudioOutputDevice("output-1")
        try await Task.sleep(nanoseconds: testQuietNanoseconds)
        XCTAssertEqual(session.calls.count, mark)
    }
}
