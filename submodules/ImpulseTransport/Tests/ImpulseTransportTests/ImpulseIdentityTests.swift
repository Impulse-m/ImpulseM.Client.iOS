import Foundation
import XCTest
@testable import ImpulseTransport


private let testNow: Int = 1_700_000_000
private let testSub: String = "i:0123456789abcdef0123456789abcdef"
private let otherSub: String = "i:fedcba9876543210fedcba9876543210"


private enum FakeCarrierError: Error {
    case failed
}


private final class FakeClock: ImpulseIdentityClock, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var seconds: Double


    init(seconds: Double) {
        self.seconds = seconds
    }


    func nowUnixSeconds() -> Double {
        lock.lock()
        defer {
            lock.unlock()
        }
        return seconds
    }


    func advance(bySeconds: Double) {
        lock.lock()
        defer {
            lock.unlock()
        }
        seconds += bySeconds
    }
}


private final class FakeScheduler: ImpulseIdentityScheduler, @unchecked Sendable {
    private let clock: FakeClock
    private let parks: Bool
    private let lock: NSLock = NSLock()
    private var sleeps: [Double] = []


    /// A parked scheduler records the sleep and waits until cancelled. An immediate one advances the fake clock.
    init(
        clock: FakeClock,
        parks: Bool
    ) {
        self.clock = clock
        self.parks = parks
    }


    func sleep(seconds: Double) async throws {
        record(seconds)
        if parks {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return
        }
        clock.advance(bySeconds: seconds)
    }


    func recordedSleeps() -> [Double] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return sleeps
    }


    private func record(_ seconds: Double) {
        lock.lock()
        defer {
            lock.unlock()
        }
        sleeps.append(seconds)
    }
}


private final class FakeCarrier: ImpulseIdentityCarrier, @unchecked Sendable {
    struct Call: Equatable {
        let identityToken: String
        let apiId: Int32
        let timeoutSeconds: Double
    }


    enum Step {
        case reply(String)
        case fail
    }


    private let lock: NSLock = NSLock()
    private var steps: [Step]
    private var calls: [Call] = []


    init(steps: [Step]) {
        self.steps = steps
    }


    func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String {
        let step: Step = nextStep(
            Call(
                identityToken: identityToken,
                apiId: apiId,
                timeoutSeconds: timeoutSeconds
            )
        )
        switch step {
        case .reply(let token):
            return token

        case .fail:
            throw FakeCarrierError.failed
        }
    }


    func recordedCalls() -> [Call] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return calls
    }


    private func nextStep(_ call: Call) -> Step {
        lock.lock()
        defer {
            lock.unlock()
        }
        calls.append(call)
        if steps.isEmpty {
            return .fail
        }
        return steps.removeFirst()
    }
}


private final class FakeStore: ImpulseIdentityStore, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [String: String] = [:]


    func string(forKey key: String) -> String? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return values[key]
    }


    func setString(
        _ value: String,
        forKey key: String
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        values[key] = value
    }


    func removeValue(forKey key: String) {
        lock.lock()
        defer {
            lock.unlock()
        }
        values[key] = nil
    }
}


private final class EventRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var events: [ImpulseIdentityEvent] = []


    func append(_ event: ImpulseIdentityEvent) {
        lock.lock()
        defer {
            lock.unlock()
        }
        events.append(event)
    }


    func recorded() -> [ImpulseIdentityEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return events
    }
}


final class ImpulseIdentityTests: XCTestCase {
    func testObtainMintsWithEmptyTokenAndThirtySecondTimeout() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let carrier: FakeCarrier = FakeCarrier(steps: [.reply(token)])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: true)
        let manager: ImpulseIdentityManager = makeManager(carrier: carrier, store: FakeStore(), clock: clock, scheduler: scheduler)

        let obtained: String = try await manager.obtain()

        XCTAssertEqual(obtained, token)
        let calls: [FakeCarrier.Call] = carrier.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.identityToken, "")
        XCTAssertEqual(calls.first?.apiId, 4)
        XCTAssertEqual(calls.first?.timeoutSeconds, 30)
    }


    func testMintPersistsUnderIdentityTokenKey() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let store: FakeStore = FakeStore()
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        _ = try await manager.obtain()

        XCTAssertEqual(store.string(forKey: "identity_token"), token)
    }


    func testConcurrentObtainsShareOneMint() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let carrier: FakeCarrier = FakeCarrier(steps: [.reply(token)])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: carrier,
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        async let first: String = manager.obtain()
        async let second: String = manager.obtain()
        let firstToken: String = try await first
        let secondToken: String = try await second

        XCTAssertEqual(firstToken, token)
        XCTAssertEqual(secondToken, token)
        XCTAssertEqual(carrier.recordedCalls().count, 1)
    }


    func testMintRejectsEmptyReply() async throws {
        let store: FakeStore = FakeStore()
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply("")]),
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        await assertObtainFails(manager, with: .emptyReply)
        XCTAssertNil(store.string(forKey: "identity_token"))
    }


    func testMintRejectsUnreadableToken() async throws {
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply("not-a-jwt")]),
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        await assertObtainFails(manager, with: .unreadableToken)
    }


    func testMintRejectsTokenWithoutSub() async throws {
        let token: String = makeToken(sub: nil, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        await assertObtainFails(manager, with: .unreadableToken)
    }


    func testMintRejectsExpiredToken() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow - 1, iat: testNow - 100, origIat: testNow - 100)
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        await assertObtainFails(manager, with: .expiredToken)
    }


    func testCurrentIsNilBeforeMintAndUsableAfter() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        let before: String? = await manager.current()
        XCTAssertNil(before)

        _ = try await manager.obtain()
        let after: String? = await manager.current()
        XCTAssertEqual(after, token)
    }


    func testUsableWindowEndsAtSixtySecondsBeforeExpiry() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let store: FakeStore = FakeStore()
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )
        _ = try await manager.obtain()

        clock.advance(bySeconds: 86_339)
        let stillUsable: String? = await manager.current()
        XCTAssertEqual(stillUsable, token)

        clock.advance(bySeconds: 1)
        let expired: String? = await manager.current()
        XCTAssertNil(expired)
        XCTAssertNil(store.string(forKey: "identity_token"))
    }


    func testDiscardClearsMemoryAndStore() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let store: FakeStore = FakeStore()
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )
        _ = try await manager.obtain()

        await manager.discard()

        let current: String? = await manager.current()
        XCTAssertNil(current)
        XCTAssertNil(store.string(forKey: "identity_token"))
    }


    func testRefuseDiscardsOnlyTheCurrentIdentity() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: [.reply(token)]),
            store: FakeStore(),
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )
        let recorder: EventRecorder = EventRecorder()
        let listener: @Sendable (ImpulseIdentityEvent) -> Void = { (event: ImpulseIdentityEvent) -> Void in
            recorder.append(event)
        }
        await manager.setListener(listener)
        _ = try await manager.obtain()

        let otherRefused: Bool = await manager.refuse("some-other-token")
        XCTAssertFalse(otherRefused)
        XCTAssertEqual(recorder.recorded(), [])

        let currentRefused: Bool = await manager.refuse(token)
        XCTAssertTrue(currentRefused)
        XCTAssertEqual(recorder.recorded(), [.changed])
        let current: String? = await manager.current()
        XCTAssertNil(current)
    }


    func testLoadsUsableStoredIdentityAtInitWithoutMinting() async throws {
        let token: String = makeToken(sub: testSub, exp: testNow + 86_400, iat: testNow, origIat: testNow)
        let store: FakeStore = FakeStore()
        store.setString(token, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: carrier,
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        let current: String? = await manager.current()

        XCTAssertEqual(current, token)
        XCTAssertEqual(carrier.recordedCalls().count, 0)
    }


    func testExpiredOrUnreadableStoredIdentityIsClearedAtInit() async throws {
        let expiring: String = makeToken(sub: testSub, exp: testNow + 30, iat: testNow, origIat: testNow)
        let expiringStore: FakeStore = FakeStore()
        expiringStore.setString(expiring, forKey: "identity_token")
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let expiringManager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: []),
            store: expiringStore,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        let expiringCurrent: String? = await expiringManager.current()
        XCTAssertNil(expiringCurrent)
        XCTAssertNil(expiringStore.string(forKey: "identity_token"))

        let garbageStore: FakeStore = FakeStore()
        garbageStore.setString("garbage", forKey: "identity_token")
        let garbageManager: ImpulseIdentityManager = makeManager(
            carrier: FakeCarrier(steps: []),
            store: garbageStore,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: true)
        )

        let garbageCurrent: String? = await garbageManager.current()
        XCTAssertNil(garbageCurrent)
        XCTAssertNil(garbageStore.string(forKey: "identity_token"))
    }


    func testRenewalPointStaysInsideTheWindow() {
        let atStart: Double = ImpulseIdentityRules.renewalPoint(expSeconds: 1000, nowSeconds: 0, fraction: 0)
        XCTAssertEqual(atStart, 700)

        let middle: Double = ImpulseIdentityRules.renewalPoint(expSeconds: 1000, nowSeconds: 0, fraction: 0.5)
        XCTAssertEqual(middle, 790)

        let nearEnd: Double = ImpulseIdentityRules.renewalPoint(expSeconds: 1000, nowSeconds: 0, fraction: 0.999)
        XCTAssertLessThan(nearEnd, 880)
        XCTAssertGreaterThanOrEqual(nearEnd, 700)

        let lateStart: Double = ImpulseIdentityRules.renewalPoint(expSeconds: 1000, nowSeconds: 750, fraction: 0)
        XCTAssertEqual(lateStart, 750)

        let closed: Double = ImpulseIdentityRules.renewalPoint(expSeconds: 1000, nowSeconds: 900, fraction: 0.5)
        XCTAssertEqual(closed, 900)
    }


    func testSameIdentityRule() {
        let before: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: testSub, exp: 2000, iat: 100, origIat: 100)

        let renewed: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: testSub, exp: 2500, iat: 900, origIat: 100)
        XCTAssertTrue(ImpulseIdentityRules.isSameIdentity(before: before, after: renewed))

        let unchangedIat: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: testSub, exp: 2500, iat: 100, origIat: 100)
        XCTAssertFalse(ImpulseIdentityRules.isSameIdentity(before: before, after: unchangedIat))

        let otherOrigin: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: testSub, exp: 2500, iat: 900, origIat: 500)
        XCTAssertFalse(ImpulseIdentityRules.isSameIdentity(before: before, after: otherOrigin))

        let otherSubject: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: otherSub, exp: 2500, iat: 900, origIat: 100)
        XCTAssertFalse(ImpulseIdentityRules.isSameIdentity(before: before, after: otherSubject))

        let noOrigin: ImpulseIdentityClaims = ImpulseIdentityClaims(sub: testSub, exp: 2500, iat: 900, origIat: nil)
        XCTAssertFalse(ImpulseIdentityRules.isSameIdentity(before: before, after: noOrigin))
    }


    func testRenewalSameIdentityEmitsRenewedAndStoresTheNewToken() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let renewedToken: String = makeToken(sub: testSub, exp: testNow + 1500, iat: testNow, origIat: testNow - 100)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [.reply(renewedToken)])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: false)
        let manager: ImpulseIdentityManager = makeManager(carrier: carrier, store: store, clock: clock, scheduler: scheduler)
        await manager.setRenewalCarrier(carrier)
        let recorder: EventRecorder = EventRecorder()
        let listener: @Sendable (ImpulseIdentityEvent) -> Void = { (event: ImpulseIdentityEvent) -> Void in
            recorder.append(event)
        }
        await manager.setListener(listener)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        let install: ImpulseIdentityInstall? = await manager.runRenewal(of: record, epochAtInstall: epoch)

        XCTAssertEqual(install?.record.token, renewedToken)
        XCTAssertEqual(install?.epoch, 0)
        XCTAssertEqual(recorder.recorded(), [.renewed(token: renewedToken)])
        XCTAssertEqual(store.string(forKey: "identity_token"), renewedToken)
        XCTAssertEqual(scheduler.recordedSleeps(), [700])
        let calls: [FakeCarrier.Call] = carrier.recordedCalls()
        XCTAssertEqual(calls.first?.identityToken, current)
        XCTAssertEqual(calls.first?.timeoutSeconds, 30)
    }


    func testRenewalOfADifferentIdentityBumpsTheEpochAndReportsChange() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let replacement: String = makeToken(sub: otherSub, exp: testNow + 1500, iat: testNow, origIat: testNow)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [.reply(replacement)])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let manager: ImpulseIdentityManager = makeManager(
            carrier: carrier,
            store: store,
            clock: clock,
            scheduler: FakeScheduler(clock: clock, parks: false)
        )
        await manager.setRenewalCarrier(carrier)
        let recorder: EventRecorder = EventRecorder()
        let listener: @Sendable (ImpulseIdentityEvent) -> Void = { (event: ImpulseIdentityEvent) -> Void in
            recorder.append(event)
        }
        await manager.setListener(listener)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        let install: ImpulseIdentityInstall? = await manager.runRenewal(of: record, epochAtInstall: epoch)

        XCTAssertEqual(install?.epoch, 1)
        XCTAssertEqual(install?.record.token, replacement)
        XCTAssertEqual(recorder.recorded(), [.changed])
    }


    func testRenewalRetriesOnceThenSucceeds() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let renewedToken: String = makeToken(sub: testSub, exp: testNow + 1500, iat: testNow, origIat: testNow - 100)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [.fail, .reply(renewedToken)])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: false)
        let manager: ImpulseIdentityManager = makeManager(carrier: carrier, store: store, clock: clock, scheduler: scheduler)
        await manager.setRenewalCarrier(carrier)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        let install: ImpulseIdentityInstall? = await manager.runRenewal(of: record, epochAtInstall: epoch)

        XCTAssertEqual(install?.record.token, renewedToken)
        XCTAssertEqual(scheduler.recordedSleeps(), [700, 1])
        XCTAssertEqual(carrier.recordedCalls().count, 2)
    }


    func testRenewalBacksOffDoublingToSixtySecondsUntilWindowEnd() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: false)
        let manager: ImpulseIdentityManager = makeManager(carrier: carrier, store: store, clock: clock, scheduler: scheduler)
        await manager.setRenewalCarrier(carrier)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        let install: ImpulseIdentityInstall? = await manager.runRenewal(of: record, epochAtInstall: epoch)

        XCTAssertNil(install)
        XCTAssertEqual(scheduler.recordedSleeps(), [700, 1, 2, 4, 8, 16, 32, 60])
        XCTAssertEqual(carrier.recordedCalls().count, 8)
    }


    func testRenewalWithoutRenewalCarrierDoesNothing() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let carrier: FakeCarrier = FakeCarrier(steps: [])
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: false)
        let manager: ImpulseIdentityManager = makeManager(carrier: carrier, store: store, clock: clock, scheduler: scheduler)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        let install: ImpulseIdentityInstall? = await manager.runRenewal(of: record, epochAtInstall: epoch)

        XCTAssertNil(install)
        XCTAssertEqual(scheduler.recordedSleeps(), [700])
        XCTAssertEqual(carrier.recordedCalls().count, 0)
    }


    func testRenewalLoopDropsTheIdentityAtSixtySecondsBeforeExpiry() async throws {
        let current: String = makeToken(sub: testSub, exp: testNow + 1000, iat: testNow - 100, origIat: testNow - 100)
        let store: FakeStore = FakeStore()
        store.setString(current, forKey: "identity_token")
        let clock: FakeClock = FakeClock(seconds: Double(testNow))
        let scheduler: FakeScheduler = FakeScheduler(clock: clock, parks: false)
        let manager: ImpulseIdentityManager = makeManager(carrier: FakeCarrier(steps: []), store: store, clock: clock, scheduler: scheduler)
        let optionalRecord: ImpulseIdentityRecord? = await manager.currentRecord()
        let record: ImpulseIdentityRecord = try XCTUnwrap(optionalRecord)
        let epoch: Int = await manager.currentEpoch

        await manager.renewalLoop(from: record, epochAtInstall: epoch)

        XCTAssertEqual(scheduler.recordedSleeps(), [700, 240])
        XCTAssertNil(store.string(forKey: "identity_token"))
        let remaining: String? = await manager.current()
        XCTAssertNil(remaining)
    }


    private func makeManager(
        carrier: FakeCarrier,
        store: FakeStore,
        clock: FakeClock,
        scheduler: FakeScheduler
    ) -> ImpulseIdentityManager {
        return ImpulseIdentityManager(
            poolCarrier: carrier,
            store: store,
            clock: clock,
            scheduler: scheduler,
            apiId: 4,
            drawFraction: { () -> Double in
                return 0
            }
        )
    }


    private func assertObtainFails(
        _ manager: ImpulseIdentityManager,
        with expected: ImpulseIdentityError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await manager.obtain()
            XCTFail("obtain should have thrown", file: file, line: line)
        } catch let error as ImpulseIdentityError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }


    /// A JWT with a fixed header and signature; only the payload is read by the client.
    private func makeToken(
        sub: String?,
        exp: Int,
        iat: Int?,
        origIat: Int?
    ) -> String {
        var payload: [String: Any] = ["exp": exp]
        if let sub: String = sub {
            payload["sub"] = sub
        }
        if let iat: Int = iat {
            payload["iat"] = iat
        }
        if let origIat: Int = origIat {
            payload["orig_iat"] = origIat
        }

        let json: Data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let encoded: String = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9." + encoded + ".c2lnbmF0dXJl"
    }
}
