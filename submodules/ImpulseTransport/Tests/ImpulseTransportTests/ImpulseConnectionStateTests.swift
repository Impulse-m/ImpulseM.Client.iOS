import XCTest
@testable import ImpulseTransport

final class ImpulseConnectionStateTests: XCTestCase {
    private let allStates: [ImpulseConnectionState] = [
        .disconnected,
        .connectingIdentity,
        .identityReady,
        .connectingSession,
        .sessionReady,
        .refreshing,
        .failed(.auth),
    ]


    func testFreshStartMintsIdentityThenReadiesSession() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine()

        XCTAssertTrue(machine.apply(.mintSucceeded(hasSession: false)))
        XCTAssertEqual(machine.state, .connectingIdentity)
        XCTAssertTrue(machine.apply(.socketReady))
        XCTAssertEqual(machine.state, .identityReady)
        XCTAssertTrue(machine.apply(.sessionAvailable))
        XCTAssertEqual(machine.state, .connectingSession)
        XCTAssertTrue(machine.apply(.socketReady))
        XCTAssertEqual(machine.state, .sessionReady)
    }


    func testStoredSessionSkipsIdentityStates() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine()

        XCTAssertTrue(machine.apply(.mintSucceeded(hasSession: true)))
        XCTAssertEqual(machine.state, .connectingSession)
        XCTAssertTrue(machine.apply(.socketReady))
        XCTAssertEqual(machine.state, .sessionReady)
    }


    func testRefreshRoundTripReturnsToSessionReady() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine(state: .sessionReady)

        XCTAssertTrue(machine.apply(.refreshDue))
        XCTAssertEqual(machine.state, .refreshing)
        XCTAssertTrue(machine.apply(.refreshSucceeded))
        XCTAssertEqual(machine.state, .sessionReady)
    }


    func testUnrecoverableRefreshFailsWithAuthAndIdentityCanBeMintedAgain() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine(state: .refreshing)

        XCTAssertTrue(machine.apply(.refreshUnrecoverable))
        XCTAssertEqual(machine.state, .failed(.auth))
        XCTAssertTrue(machine.apply(.mintSucceeded(hasSession: false)))
        XCTAssertEqual(machine.state, .connectingIdentity)
    }


    func testNetworkLossMovesEveryStateToDisconnected() {
        for state: ImpulseConnectionState in allStates {
            var machine: ImpulseConnectionMachine = ImpulseConnectionMachine(state: state)

            machine.apply(.networkLost)

            XCTAssertEqual(machine.state, .disconnected)
        }
    }


    func testEventsOutsideTheirSourceStateAreRefused() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine()

        XCTAssertFalse(machine.apply(.socketReady))
        XCTAssertFalse(machine.apply(.refreshDue))
        XCTAssertFalse(machine.apply(.refreshSucceeded))
        XCTAssertFalse(machine.apply(.refreshUnrecoverable))
        XCTAssertFalse(machine.apply(.sessionAvailable))
        XCTAssertEqual(machine.state, .disconnected)

        var ready: ImpulseConnectionMachine = ImpulseConnectionMachine(state: .sessionReady)
        XCTAssertFalse(ready.apply(.mintSucceeded(hasSession: true)))
        XCTAssertFalse(ready.apply(.refreshSucceeded))
        XCTAssertEqual(ready.state, .sessionReady)
    }


    func testSessionReadyCannotSkipRefreshingToFailure() {
        var machine: ImpulseConnectionMachine = ImpulseConnectionMachine(state: .sessionReady)

        XCTAssertFalse(machine.apply(.refreshUnrecoverable))
        XCTAssertEqual(machine.state, .sessionReady)
    }


    func testIndicatorOfflineIsWaitingForNetworkInEveryState() {
        for state: ImpulseConnectionState in allStates {
            XCTAssertEqual(state.indicator(networkAvailable: false, requestInFlight: true), .waitingForNetwork)
        }
    }


    func testIndicatorOfConnectingStatesAndFailure() {
        XCTAssertEqual(ImpulseConnectionState.disconnected.indicator(networkAvailable: true, requestInFlight: false), .connecting)
        XCTAssertEqual(ImpulseConnectionState.connectingIdentity.indicator(networkAvailable: true, requestInFlight: false), .connecting)
        XCTAssertEqual(ImpulseConnectionState.connectingSession.indicator(networkAvailable: true, requestInFlight: false), .connecting)
        XCTAssertEqual(ImpulseConnectionState.failed(.auth).indicator(networkAvailable: true, requestInFlight: false), .connecting)
    }


    func testIndicatorOfReadyStatesFollowsRequestInFlight() {
        XCTAssertEqual(ImpulseConnectionState.identityReady.indicator(networkAvailable: true, requestInFlight: false), .connected)
        XCTAssertEqual(ImpulseConnectionState.identityReady.indicator(networkAvailable: true, requestInFlight: true), .updating)
        XCTAssertEqual(ImpulseConnectionState.sessionReady.indicator(networkAvailable: true, requestInFlight: false), .connected)
        XCTAssertEqual(ImpulseConnectionState.sessionReady.indicator(networkAvailable: true, requestInFlight: true), .updating)
    }


    func testIndicatorOfRefreshingIsUpdating() {
        XCTAssertEqual(ImpulseConnectionState.refreshing.indicator(networkAvailable: true, requestInFlight: false), .updating)
    }


    func testReconnectBackoffDoublesFromOneToThirtySeconds() {
        var backoff: ImpulseReconnectBackoff = ImpulseReconnectBackoff()
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            delays.append(backoff.nextDelay())
        }

        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30])
    }


    func testReconnectBackoffResetsAfterConnect() {
        var backoff: ImpulseReconnectBackoff = ImpulseReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), 1)
    }


    func testSyncIntervalIsFiveSeconds() {
        XCTAssertEqual(ImpulseSyncPlanner.syncIntervalSeconds, 5)
    }


    func testLoggedInOnlineConnectsAndSubscribesUserLane() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        let plan: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)

        XCTAssertTrue(plan.connect)
        XCTAssertFalse(plan.disconnect)
        XCTAssertEqual(plan.subscribeUserLane, 5)
        XCTAssertEqual(plan.dropUserLane, 0)
    }


    func testLogoutDropsTheUserLaneOnce() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 5, sessionPresent: true, online: true)
        let out: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)

        XCTAssertTrue(out.stopLanes)
        XCTAssertTrue(out.connect)
        XCTAssertEqual(out.dropUserLane, 5)
        XCTAssertEqual(out.subscribeUserLane, 0)

        let steady: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)
        XCTAssertEqual(steady.dropUserLane, 0)
    }


    func testMissingSessionCountsAsLoggedOut() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        let plan: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: false, online: true)

        XCTAssertTrue(plan.connect)
        XCTAssertFalse(plan.disconnect)
        XCTAssertTrue(plan.stopLanes)
        XCTAssertEqual(plan.subscribeUserLane, 0)
    }


    func testSignedOutOnlineConnectsWithoutLane() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        let plan: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)

        XCTAssertTrue(plan.connect)
        XCTAssertFalse(plan.disconnect)
        XCTAssertEqual(plan.subscribeUserLane, 0)
        XCTAssertEqual(plan.dropUserLane, 0)
    }


    func testFirstConnectIsNotARekey() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        let plan: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)

        XCTAssertFalse(plan.disconnect)
        XCTAssertTrue(plan.connect)
    }


    func testSignInRekeysOnce() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 0, sessionPresent: false, online: true)
        let signedIn: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)

        XCTAssertTrue(signedIn.disconnect)
        XCTAssertTrue(signedIn.connect)
        XCTAssertEqual(signedIn.subscribeUserLane, 5)

        let steady: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)
        XCTAssertFalse(steady.disconnect)
        XCTAssertTrue(steady.connect)
    }


    func testSignOutRekeysOnce() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 5, sessionPresent: true, online: true)
        let signedOut: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)

        XCTAssertTrue(signedOut.disconnect)
        XCTAssertTrue(signedOut.connect)

        let steady: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)
        XCTAssertFalse(steady.disconnect)
        XCTAssertTrue(steady.connect)
    }


    func testOfflineDisconnectsInEitherKindWithoutConnecting() async {
        let identity: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await identity.plan(userId: 0, sessionPresent: false, online: true)
        let offlineIdentity: ImpulseSyncPlan = await identity.plan(userId: 0, sessionPresent: false, online: false)

        XCTAssertTrue(offlineIdentity.disconnect)
        XCTAssertFalse(offlineIdentity.connect)

        let session: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await session.plan(userId: 5, sessionPresent: true, online: true)
        let offlineSession: ImpulseSyncPlan = await session.plan(userId: 5, sessionPresent: true, online: false)

        XCTAssertTrue(offlineSession.disconnect)
        XCTAssertFalse(offlineSession.connect)
        XCTAssertFalse(offlineSession.stopLanes)
        XCTAssertEqual(offlineSession.dropUserLane, 0)
    }


    func testNetworkReturnReconnectsOnce() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 5, sessionPresent: true, online: true)
        _ = await planner.plan(userId: 5, sessionPresent: true, online: false)
        let back: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)

        XCTAssertTrue(back.disconnect)
        XCTAssertTrue(back.connect)

        let steady: ImpulseSyncPlan = await planner.plan(userId: 5, sessionPresent: true, online: true)
        XCTAssertFalse(steady.disconnect)
        XCTAssertTrue(steady.connect)
    }


    func testUserSwitchDropsPreviousLaneAndDisconnects() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 5, sessionPresent: true, online: true)
        let plan: ImpulseSyncPlan = await planner.plan(userId: 6, sessionPresent: true, online: true)

        XCTAssertEqual(plan.dropUserLane, 5)
        XCTAssertTrue(plan.stopLanes)
        XCTAssertEqual(plan.subscribeUserLane, 6)
        XCTAssertTrue(plan.disconnect)
        XCTAssertTrue(plan.connect)
    }


    func testCredentialKindChangeRekeys() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 0, sessionPresent: false, online: true)
        let plan: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: true, online: true)

        XCTAssertTrue(plan.disconnect)
        XCTAssertTrue(plan.connect)
    }


    func testConcurrentTriggersDropTheLaneExactlyOnce() async {
        let planner: ImpulseSyncPlanner = ImpulseSyncPlanner()
        _ = await planner.plan(userId: 5, sessionPresent: true, online: true)

        let drops: Int = await withTaskGroup(of: Int.self) { (group: inout TaskGroup<Int>) -> Int in
            for _ in 0..<8 {
                group.addTask {
                    var count: Int = 0
                    for _ in 0..<100 {
                        let plan: ImpulseSyncPlan = await planner.plan(userId: 0, sessionPresent: false, online: true)
                        if plan.dropUserLane == 5 {
                            count += 1
                        }
                    }

                    return count
                }
            }

            var total: Int = 0
            for await count in group {
                total += count
            }

            return total
        }

        XCTAssertEqual(drops, 1)
    }
}
