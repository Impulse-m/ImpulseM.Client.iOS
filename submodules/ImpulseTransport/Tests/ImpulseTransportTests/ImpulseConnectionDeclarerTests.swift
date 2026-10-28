import XCTest
@testable import ImpulseTransport


private final class DeclarerCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private var sentMethods: [String] = []
    private var sentPayloads: [[UInt8]] = []
    private let delayNanoseconds: UInt64


    init(
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        delayNanoseconds: UInt64 = 0
    ) {
        self.replies = replies
        self.delayNanoseconds = delayNanoseconds
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let reply: Result<[UInt8], ImpulseCarrierFailure> = self.recordSend(method: method, data: data)
        if self.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: self.delayNanoseconds)
        }
        return reply
    }


    func methods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentMethods
    }


    func payloads() -> [[UInt8]] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentPayloads
    }


    private func recordSend(
        method: String,
        data: [UInt8]
    ) -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.sentMethods.append(method)
        self.sentPayloads.append(data)
        if self.replies.isEmpty {
            return .success([])
        }
        return self.replies.removeFirst()
    }
}


private final class DeclarerClock: ImpulseRequestClock, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var sleeps: [TimeInterval] = []


    func nowSeconds() -> TimeInterval {
        return 0
    }


    func sleep(seconds: TimeInterval) async throws {
        self.recordSleep(seconds: seconds)
    }


    func recorded() -> [TimeInterval] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sleeps
    }


    private func recordSleep(seconds: TimeInterval) {
        self.lock.lock()
        self.sleeps.append(seconds)
        self.lock.unlock()
    }
}


private final class DeclarerCredentials: ImpulseConnectionCredentials, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: String?


    init(value: String?) {
        self.value = value
    }


    func currentCredential() -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.value
    }


    func set(_ newValue: String?) {
        self.lock.lock()
        self.value = newValue
        self.lock.unlock()
    }
}


private final class DeclarationOutcomes: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [ImpulseDeclarationOutcome] = []


    func append(_ outcome: ImpulseDeclarationOutcome) {
        self.lock.lock()
        self.values.append(outcome)
        self.lock.unlock()
    }


    func all() -> [ImpulseDeclarationOutcome] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.values
    }
}


private func makeDeclaration(langCode: String = "en") -> ImpulseDeclaration {
    return ImpulseDeclaration(
        apiId: 2040,
        deviceModel: "Mac",
        systemVersion: "15.0",
        appVersion: "1.0",
        systemLangCode: "en",
        langPack: "macos",
        langCode: langCode
    )
}


private func makeReporter(_ outcomes: DeclarationOutcomes) -> ImpulseDeclarationReporter {
    return { (outcome: ImpulseDeclarationOutcome, attempt: Int, code: Int) -> Void in
        outcomes.append(outcome)
    }
}


private func networkFailure() -> ImpulseCarrierFailure {
    return ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
}


private func rpcFailure(
    appCode: Int,
    appType: String
) -> ImpulseCarrierFailure {
    return ImpulseCarrierFailure(sdkCode: 0, appCode: appCode, appType: appType, metadata: [:])
}


/// Lets the actor run the work it has queued.
private func settle() async {
    try? await Task.sleep(nanoseconds: 50_000_000)
}


private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<300 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}


final class ImpulseConnectionDeclarerTests: XCTestCase {
    func testDeclaresTheCurrentPairOnce() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )
        let declaration: ImpulseDeclaration = makeDeclaration()

        await declarer.setDeclaration(declaration)
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.methods(), ["initConnection"])
        XCTAssertEqual(carrier.payloads(), [declaration.initConnectionRequest()])
    }


    func testSessionChangeWithTheSamePairSendsNothing() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )
        await declarer.setDeclaration(makeDeclaration())
        _ = await declarer.awaitDeclared(timeoutSeconds: 2)

        await declarer.sessionChanged()
        await settle()

        XCTAssertEqual(carrier.methods().count, 1)
    }


    func testNewCredentialDeclaresTheNewPair() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let credentials: DeclarerCredentials = DeclarerCredentials(value: "identity-1")
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: credentials,
            clock: DeclarerClock()
        )
        await declarer.setDeclaration(makeDeclaration())
        _ = await declarer.awaitDeclared(timeoutSeconds: 2)

        credentials.set("access-1")
        await declarer.credentialChanged()
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.methods(), ["initConnection", "initConnection"])
    }


    func testLanguageSwitchDeclaresTheNewDeclaration() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )
        await declarer.setDeclaration(makeDeclaration(langCode: "en"))
        _ = await declarer.awaitDeclared(timeoutSeconds: 2)

        await declarer.setLangCode("fr")
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.payloads().last, makeDeclaration(langCode: "fr").initConnectionRequest())
        XCTAssertEqual(carrier.methods().count, 2)
    }


    func testLanguageSetBeforeTheDeclarationIsKept() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )

        await declarer.setLangCode("de")
        await declarer.setDeclaration(makeDeclaration(langCode: "en"))
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.payloads(), [makeDeclaration(langCode: "de").initConnectionRequest()])
    }


    func testNetworkFailuresAreRetriedWithTheRequestWait() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [
            .failure(networkFailure()),
            .success([]),
        ])
        let clock: DeclarerClock = DeclarerClock()
        let outcomes: DeclarationOutcomes = DeclarationOutcomes()
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: clock,
            reporter: makeReporter(outcomes)
        )

        await declarer.setDeclaration(makeDeclaration())
        _ = await declarer.awaitDeclared(timeoutSeconds: 2)
        await waitUntil { outcomes.all().contains(.ok) }
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.methods().count, 2)
        XCTAssertEqual(clock.recorded(), [1])
        XCTAssertEqual(outcomes.all(), [.retry, .ok])
    }


    func testGivesUpAfterTheMaximumAttempts() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [
            .failure(networkFailure()),
            .failure(networkFailure()),
            .failure(networkFailure()),
        ])
        let clock: DeclarerClock = DeclarerClock()
        let outcomes: DeclarationOutcomes = DeclarationOutcomes()
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: clock,
            reporter: makeReporter(outcomes)
        )

        await declarer.setDeclaration(makeDeclaration())
        await waitUntil { outcomes.all().contains(.gaveUp) }
        await settle()

        XCTAssertEqual(ImpulseConnectionDeclarer.maxAttempts, 3)
        XCTAssertEqual(carrier.methods().count, 3)
        XCTAssertEqual(clock.recorded(), [1, 2])
        XCTAssertEqual(outcomes.all(), [.retry, .retry, .gaveUp])
    }


    func testAuthorizationFailureEndsTheRunAsSessionLost() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [
            .failure(rpcFailure(appCode: 401, appType: "AUTH_KEY_UNREGISTERED")),
        ])
        let outcomes: DeclarationOutcomes = DeclarationOutcomes()
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock(),
            reporter: makeReporter(outcomes)
        )

        await declarer.setDeclaration(makeDeclaration())
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertFalse(declared)
        XCTAssertEqual(carrier.methods().count, 1)
        XCTAssertEqual(outcomes.all(), [.sessionLost])
    }


    func testDeliveredErrorEndsTheRunWithoutRetry() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [
            .failure(rpcFailure(appCode: 400, appType: "PHONE_NUMBER_INVALID")),
        ])
        let outcomes: DeclarationOutcomes = DeclarationOutcomes()
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock(),
            reporter: makeReporter(outcomes)
        )

        await declarer.setDeclaration(makeDeclaration())
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertFalse(declared)
        XCTAssertEqual(carrier.methods().count, 1)
        XCTAssertEqual(outcomes.all(), [.gaveUp])
    }


    func testNoCredentialSendsNothing() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: nil),
            clock: DeclarerClock()
        )

        await declarer.setDeclaration(makeDeclaration())
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertFalse(declared)
        XCTAssertEqual(carrier.methods(), [])
    }


    func testInvalidateDeclaresTheSamePairAgain() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [])
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )
        await declarer.setDeclaration(makeDeclaration())
        _ = await declarer.awaitDeclared(timeoutSeconds: 2)

        await declarer.invalidate()
        let declared: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertTrue(declared)
        XCTAssertEqual(carrier.methods().count, 2)
    }


    func testAwaitEndsWithFalseWhenTheDeclarationIsSlow() async {
        let carrier: DeclarerCarrier = DeclarerCarrier(replies: [], delayNanoseconds: 500_000_000)
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: carrier,
            credentials: DeclarerCredentials(value: "token-1"),
            clock: DeclarerClock()
        )
        await declarer.setDeclaration(makeDeclaration())

        let early: Bool = await declarer.awaitDeclared(timeoutSeconds: 0.05)
        let later: Bool = await declarer.awaitDeclared(timeoutSeconds: 2)

        XCTAssertFalse(early)
        XCTAssertTrue(later)
        XCTAssertEqual(carrier.methods().count, 1)
    }
}
