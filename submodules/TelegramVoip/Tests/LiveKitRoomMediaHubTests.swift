import XCTest
@testable import TelegramVoip


final class LiveKitRoomMediaRegistryTests: XCTestCase {
    func testKeyIsReportedOnceAndForgottenOnRemoval() {
        let registry: LiveKitAudioTrackRegistry = LiveKitAudioTrackRegistry()
        var madeCount: Int = 0

        let first: LiveKitAudioTrackHandle? = registry.register(key: "s1", makeHandle: {
            madeCount += 1
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })
        let duplicate: LiveKitAudioTrackHandle? = registry.register(key: "s1", makeHandle: {
            madeCount += 1
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        XCTAssertEqual(madeCount, 1)
        XCTAssertNotNil(registry.unregister(key: "s1"))
        XCTAssertNil(registry.unregister(key: "s1"))
    }


    func testRemovedKeyCanBeRegisteredAgain() {
        let registry: LiveKitAudioTrackRegistry = LiveKitAudioTrackRegistry()
        _ = registry.register(key: "s1", makeHandle: {
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })
        _ = registry.unregister(key: "s1")

        let again: LiveKitAudioTrackHandle? = registry.register(key: "s1", makeHandle: {
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })

        XCTAssertNotNil(again)
    }


    func testUnknownKeyIsNotReported() {
        let registry: LiveKitAudioTrackRegistry = LiveKitAudioTrackRegistry()

        XCTAssertNil(registry.unregister(key: "missing"))
    }
}


/// Collects the hub deliveries of one test. The test runs on the main actor, as the hub's callbacks do.
private final class AudioTrackDeliveryRecorder {
    var availableIdentities: [String] = []
    var removedIdentities: [String] = []
}


final class LiveKitRoomMediaHubTests: XCTestCase {
    @MainActor
    func testEachTrackIsDeliveredOnceAndEachRemovalOnce() async {
        let hub: LiveKitAudioTrackHub = LiveKitAudioTrackHub()
        let recorder: AudioTrackDeliveryRecorder = AudioTrackDeliveryRecorder()
        let availableMarker: XCTestExpectation = expectation(description: "The marker track is delivered as available")
        let removedMarker: XCTestExpectation = expectation(description: "The marker track is delivered as removed")

        hub.availableHandler = { (handle: LiveKitAudioTrackHandle) in
            recorder.availableIdentities.append(handle.participantIdentity)
            if handle.participantIdentity == "marker" {
                availableMarker.fulfill()
            }
        }
        hub.removedHandler = { (handle: LiveKitAudioTrackHandle) in
            recorder.removedIdentities.append(handle.participantIdentity)
            if handle.participantIdentity == "marker" {
                removedMarker.fulfill()
            }
        }

        hub.trackDidAppear(key: "s1", makeHandle: {
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })
        hub.trackDidAppear(key: "s1", makeHandle: {
            return FakeLiveKitAudioTrackHandle(participantIdentity: "u1.1", isLocal: false)
        })
        hub.trackDidGoAway(key: "s1")
        hub.trackDidGoAway(key: "s1")

        // Deliveries reach the main actor in the order they were queued, so the markers come after every event above.
        hub.trackDidAppear(key: "m1", makeHandle: {
            return FakeLiveKitAudioTrackHandle(participantIdentity: "marker", isLocal: true)
        })
        hub.trackDidGoAway(key: "m1")

        await fulfillment(of: [availableMarker, removedMarker], timeout: 5)
        XCTAssertEqual(recorder.availableIdentities, ["u1.1", "marker"])
        XCTAssertEqual(recorder.removedIdentities, ["u1.1", "marker"])
    }
}
