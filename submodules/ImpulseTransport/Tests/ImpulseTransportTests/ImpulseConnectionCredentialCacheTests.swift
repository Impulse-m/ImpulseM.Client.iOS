import Foundation
import XCTest
@testable import ImpulseTransport


private let fixedNowSeconds: Double = 1_700_000_000


final class ImpulseConnectionCredentialCacheTests: XCTestCase {
    func testEmptyCacheHasNoCredential() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        XCTAssertNil(cache.currentCredential())
    }


    func testIdentityIsTheCredentialWithoutASession() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        cache.setIdentityToken("identity-token")

        XCTAssertEqual(cache.currentCredential(), "identity-token")
    }


    func testSessionAccessTokenWinsOverIdentity() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        cache.setIdentityToken("identity-token")
        cache.setSessionAccessToken("access-token")

        XCTAssertEqual(cache.currentCredential(), "access-token")
    }


    func testClearingTheSessionFallsBackToIdentity() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        cache.setIdentityToken("identity-token")
        cache.setSessionAccessToken("access-token")
        cache.setSessionAccessToken(nil)

        XCTAssertEqual(cache.currentCredential(), "identity-token")
    }


    func testRefreshReplacesTheAccessToken() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        cache.setSessionAccessToken("first-token")
        cache.setSessionAccessToken("second-token")

        XCTAssertEqual(cache.currentCredential(), "second-token")
    }


    func testEmptyValuesCountAsAbsent() {
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        cache.setIdentityToken("identity-token")
        cache.setSessionAccessToken("")

        XCTAssertEqual(cache.currentCredential(), "identity-token")

        cache.setIdentityToken("")

        XCTAssertNil(cache.currentCredential())
    }


    func testSynchronizeReadsTheSessionThenTheIdentityAfterClear() async throws {
        let clock: CacheFixedClock = CacheFixedClock(seconds: fixedNowSeconds)
        let identity: ImpulseIdentityManager = makeIdentity(clock: clock)
        let tokens: ImpulseTokens = makeTokens()
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()
        let identityToken: String = try makeToken(payload: identityPayload(subject: "identity-1"))
        let accessToken: String = try makeToken(payload: ["sub": "7", "exp": Int(fixedNowSeconds) + 3600])

        _ = try await identity.obtain()
        await tokens.onLoginTokens(
            ImpulseSessionTokens(
                accessToken: accessToken,
                refreshToken: "refresh-token",
                userId: 7
            )
        )
        await cache.synchronize(tokens: tokens, identity: identity)

        XCTAssertEqual(cache.currentCredential(), accessToken)

        await tokens.clear()
        await cache.synchronize(tokens: tokens, identity: identity)

        XCTAssertEqual(cache.currentCredential(), identityToken)
    }


    func testSynchronizeAfterAMintExposesTheIdentity() async throws {
        let clock: CacheFixedClock = CacheFixedClock(seconds: fixedNowSeconds)
        let identity: ImpulseIdentityManager = makeIdentity(
            clock: clock,
            subject: "identity-2"
        )
        let tokens: ImpulseTokens = makeTokens()
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()
        let identityToken: String = try makeToken(payload: identityPayload(subject: "identity-2"))

        await cache.synchronize(tokens: tokens, identity: identity)
        XCTAssertNil(cache.currentCredential())

        _ = try await identity.obtain()
        await cache.synchronize(tokens: tokens, identity: identity)

        XCTAssertEqual(cache.currentCredential(), identityToken)
    }


    func testDiscardedIdentityLeavesNoCredential() async throws {
        let clock: CacheFixedClock = CacheFixedClock(seconds: fixedNowSeconds)
        let identity: ImpulseIdentityManager = makeIdentity(clock: clock)
        let tokens: ImpulseTokens = makeTokens()
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        _ = try await identity.obtain()
        await cache.synchronize(tokens: tokens, identity: identity)
        XCTAssertNotNil(cache.currentCredential())

        await identity.discard()
        await cache.synchronize(tokens: tokens, identity: identity)

        XCTAssertNil(cache.currentCredential())
    }


    func testFollowUpdatesTheCacheOnAnIdentityEvent() async throws {
        let clock: CacheFixedClock = CacheFixedClock(seconds: fixedNowSeconds)
        let identity: ImpulseIdentityManager = makeIdentity(clock: clock)
        let tokens: ImpulseTokens = makeTokens()
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        let identityToken: String = try await identity.obtain()
        await cache.follow(tokens: tokens, identity: identity)
        XCTAssertEqual(cache.currentCredential(), identityToken)

        let refused: Bool = await identity.refuse(identityToken)
        XCTAssertTrue(refused)

        let cleared: Bool = await waitForCredential(cache: cache, expected: nil)
        XCTAssertTrue(cleared)
    }


    func testSetterAfterSynchronizeIsNotOverwritten() async throws {
        let clock: CacheFixedClock = CacheFixedClock(seconds: fixedNowSeconds)
        let identity: ImpulseIdentityManager = makeIdentity(clock: clock)
        let tokens: ImpulseTokens = makeTokens()
        let cache: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        await cache.synchronize(tokens: tokens, identity: identity)
        cache.setSessionAccessToken("late-token")

        XCTAssertEqual(cache.currentCredential(), "late-token")
    }


    private func waitForCredential(
        cache: ImpulseConnectionCredentialCache,
        expected: String?
    ) async -> Bool {
        for _ in 0..<200 {
            if cache.currentCredential() == expected {
                return true
            }

            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        return cache.currentCredential() == expected
    }


    private func identityPayload(subject: String) -> [String: Any] {
        let now: Int = Int(fixedNowSeconds)
        return [
            "sub": subject,
            "exp": now + 3600,
            "iat": now,
            "orig_iat": now,
        ]
    }


    private func makeIdentity(
        clock: CacheFixedClock,
        subject: String = "identity-1"
    ) -> ImpulseIdentityManager {
        return ImpulseIdentityManager(
            poolCarrier: CacheIdentityCarrier(token: makeTokenOrFail(payload: identityPayload(subject: subject))),
            store: CacheIdentityStore(),
            clock: clock,
            scheduler: CacheFailingScheduler(),
            apiId: 4,
            drawFraction: { () -> Double in
                return 0.5
            }
        )
    }


    private func makeTokens() -> ImpulseTokens {
        return ImpulseTokens(
            storage: CacheSessionStorage(),
            transport: CacheRefreshTransport(),
            clock: { () -> Date in
                return Date(timeIntervalSince1970: fixedNowSeconds)
            },
            randomUnit: { () -> Double in
                return 0.5
            }
        )
    }


    private func makeToken(payload: [String: Any]) throws -> String {
        let header: String = base64Url(Data("{\"alg\":\"none\"}".utf8))
        let body: Data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return header + "." + base64Url(body) + ".signature"
    }


    private func makeTokenOrFail(payload: [String: Any]) -> String {
        do {
            return try makeToken(payload: payload)
        } catch {
            XCTFail("the fixture token must encode")
            return ""
        }
    }


    private func base64Url(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}


private final class CacheFixedClock: ImpulseIdentityClock, @unchecked Sendable {
    private let seconds: Double


    init(seconds: Double) {
        self.seconds = seconds
    }


    func nowUnixSeconds() -> Double {
        return self.seconds
    }
}


private final class CacheIdentityCarrier: ImpulseIdentityCarrier, @unchecked Sendable {
    private let token: String


    init(token: String) {
        self.token = token
    }


    func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String {
        return self.token
    }
}


private final class CacheIdentityStore: ImpulseIdentityStore, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var values: [String: String] = [:]


    func string(forKey key: String) -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        return self.values[key]
    }


    func setString(
        _ value: String,
        forKey key: String
    ) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.values[key] = value
    }


    func removeValue(forKey key: String) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.values.removeValue(forKey: key)
    }
}


/// Fails every sleep at once, so no renewal loop can outlive the test.
private final class CacheFailingScheduler: ImpulseIdentityScheduler, @unchecked Sendable {
    func sleep(seconds: Double) async throws {
        throw CancellationError()
    }
}


private final class CacheSessionStorage: ImpulseSessionStorage, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: ImpulseSessionTokens?


    func load() -> ImpulseSessionTokens? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        return self.stored
    }


    func save(_ tokens: ImpulseSessionTokens) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.stored = tokens
    }


    func clear() {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.stored = nil
    }
}


private final class CacheRefreshTransport: ImpulseRefreshTransport, @unchecked Sendable {
    func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply {
        throw ImpulseTokenError.incompleteReply
    }
}
