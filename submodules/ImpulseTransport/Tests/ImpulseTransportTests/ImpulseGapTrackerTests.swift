import XCTest
@testable import ImpulseTransport

final class ImpulseGapTrackerTests: XCTestCase {
    func testRecoveredUserLaneWithoutDropNeedsNoDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertFalse(tracker.onSubscribed(channel: "user:5", recovered: true, wasRecovering: true))
    }


    func testFreshUserLaneSubscribeNeedsDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertTrue(tracker.onSubscribed(channel: "user:5", recovered: false, wasRecovering: false))
        XCTAssertTrue(tracker.onSubscribed(channel: "user:5", recovered: false, wasRecovering: true))
    }


    func testDroppedUserLanePositionNeedsDifferenceEvenIfRecovered() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "user:5", code: 2502)
        XCTAssertTrue(tracker.onSubscribed(channel: "user:5", recovered: true, wasRecovering: true))
    }


    func testFirstChannelSubscribeIsNoGap() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: false))
    }


    func testRecoveredChannelResubscribeIsNoGap() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:9", recovered: true, wasRecovering: true))
    }


    func testFailedRecoveryIsAGap() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertTrue(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: true))
    }


    func testCode2502ThenSubscribeIsAGapOnce() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "channel:9", code: 2502)
        XCTAssertTrue(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: false))
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: false))
    }


    func testOtherTemporaryCodesAreNotAGap() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "channel:9", code: 2500)
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:9", recovered: true, wasRecovering: true))
    }


    func testTerminalUnsubscribeForgetsTheMark() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "channel:9", code: 2502)
        tracker.onUnsubscribed(channel: "channel:9", code: 2000)
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: false))
    }


    func testMarkIsPerChannel() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "channel:9", code: 2502)
        XCTAssertFalse(tracker.onSubscribed(channel: "channel:10", recovered: false, wasRecovering: false))
        XCTAssertTrue(tracker.onSubscribed(channel: "channel:9", recovered: false, wasRecovering: false))
    }


    func testFreshSessionLaneSubscribeNeedsNoDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertFalse(tracker.onSubscribed(channel: "session:5:77", recovered: false, wasRecovering: false))
    }


    func testFailedSessionLaneRecoveryNeedsDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertTrue(tracker.onSubscribed(channel: "session:5:77", recovered: false, wasRecovering: true))
    }


    func testDroppedSessionLanePositionNeedsDifferenceEvenIfRecovered() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onUnsubscribed(channel: "session:5:77", code: 2502)
        XCTAssertTrue(tracker.onSubscribed(channel: "session:5:77", recovered: true, wasRecovering: true))
    }


    func testFirstConnectIsNotAReconnectDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        XCTAssertNil(tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true))
    }


    func testReconnectThenRecoveredUserLaneNeedsOneSocketReconnectedDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onReconnected()
        XCTAssertEqual(
            tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true),
            ImpulseDifferenceReason.socketReconnected
        )
        XCTAssertNil(tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true))
    }


    func testReconnectThenUnrecoveredUserLaneNeedsOneNotRecoveredDifference() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onReconnected()
        XCTAssertEqual(
            tracker.differenceReason(channel: "user:5", recovered: false, wasRecovering: true),
            ImpulseDifferenceReason.subscribeNotRecovered
        )
        XCTAssertNil(tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true))
    }


    func testReconnectIsNotSpentByChannelOrSessionLanes() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onReconnected()
        XCTAssertNil(tracker.differenceReason(channel: "channel:9", recovered: true, wasRecovering: true))
        XCTAssertNil(tracker.differenceReason(channel: "session:5:77", recovered: true, wasRecovering: true))
        XCTAssertEqual(
            tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true),
            ImpulseDifferenceReason.socketReconnected
        )
    }


    func testDroppedUserLaneAfterReconnectIsPositionDroppedOnce() {
        let tracker: ImpulseGapTracker = ImpulseGapTracker()
        tracker.onReconnected()
        tracker.onUnsubscribed(channel: "user:5", code: 2502)
        XCTAssertEqual(
            tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true),
            ImpulseDifferenceReason.subscribePositionDropped
        )
        XCTAssertNil(tracker.differenceReason(channel: "user:5", recovered: true, wasRecovering: true))
    }
}
