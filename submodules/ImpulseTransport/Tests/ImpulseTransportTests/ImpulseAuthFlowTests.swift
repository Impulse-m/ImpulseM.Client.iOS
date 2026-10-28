import XCTest
@testable import ImpulseTransport


/// Mints identities on the pool and records each mint.
private final class AuthFlowPoolCarrier: ImpulseIdentityCarrier, @unchecked Sendable {
    private(set) var mintCount: Int = 0
    private(set) var issued: [String] = []


    func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String {
        mintCount += 1
        let token: String = makeAuthFlowToken(
            sub: "i:identity\(mintCount)",
            expSeconds: 1_000_000 + 86_400,
            origIat: 1_000_000,
            iat: 1_000_000
        )
        issued.append(token)
        return token
    }
}


private final class AuthFlowIdentityStore: ImpulseIdentityStore, @unchecked Sendable {
    private(set) var values: [String: String] = [:]


    func string(forKey key: String) -> String? {
        return values[key]
    }


    func setString(
        _ value: String,
        forKey key: String
    ) {
        values[key] = value
    }


    func removeValue(forKey key: String) {
        values[key] = nil
    }
}


private final class AuthFlowStorage: ImpulseSessionStorage, @unchecked Sendable {
    private(set) var stored: ImpulseSessionTokens?


    func load() -> ImpulseSessionTokens? {
        return stored
    }


    func save(_ tokens: ImpulseSessionTokens) {
        stored = tokens
    }


    func clear() {
        stored = nil
    }
}


private struct AuthFlowClock: ImpulseIdentityClock {
    func nowUnixSeconds() -> Double {
        return 1_000_000
    }
}


/// Ends every wait at once, so the renewal of a minted identity finishes without a renewal.
private struct AuthFlowScheduler: ImpulseIdentityScheduler {
    func sleep(seconds: Double) async throws {
        throw CancellationError()
    }
}


private struct AuthFlowRefreshTransport: ImpulseRefreshTransport {
    func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply {
        return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
    }
}


/// Records the socket calls in order, and holds the listener weakly as the real socket does.
private final class AuthFlowSocket: ImpulseRealtimeSocket {
    weak var listener: (any ImpulseRealtimeSocketListener)?
    var calls: [String] = []


    func connect() {
        calls.append("connect")
    }


    func disconnect() {
        calls.append("disconnect")
    }


    func setConnectionToken(_ token: String) {
        calls.append("token " + token)
    }


    func subscribe(
        channel: String,
        positioned: Bool,
        recoverable: Bool
    ) {
        calls.append("subscribe \(channel) \(positioned) \(recoverable)")
    }


    func unsubscribe(channel: String) {
        calls.append("unsubscribe " + channel)
    }
}


private final class AuthFlowDifferences {
    private(set) var requests: [ImpulseDifferenceRequest] = []


    func record(_ request: ImpulseDifferenceRequest) {
        requests.append(request)
    }
}


/// Answers the login calls with the queued replies and records what was sent and how the login state moved.
private final class AuthFlowRequester: ImpulseAuthRequester, @unchecked Sendable {
    var replies: [Result<[UInt8], ImpulseRequestFailure>] = []
    private(set) var sentMethods: [String] = []
    private(set) var lastOptions: ImpulseRequestOptions?
    private(set) var gateStates: [Bool] = []
    var onExecute: ((String) -> Void)?


    func execute(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions
    ) async -> Result<[UInt8], ImpulseRequestFailure> {
        sentMethods.append(request.method)
        onExecute?(request.method)
        lastOptions = options
        guard !replies.isEmpty else {
            return .failure(.canceled)
        }
        return replies.removeFirst()
    }


    func setSignedIn(_ signedIn: Bool) {
        gateStates.append(signedIn)
    }
}


/// Builds a JWT-shaped token with the claims the client reads. The signature is not checked by the client.
private func makeAuthFlowToken(
    sub: String,
    expSeconds: Double,
    origIat: Double,
    iat: Double
) -> String {
    let header: String = "{\"alg\":\"none\"}"
    let payload: String = "{\"sub\":\"\(sub)\",\"exp\":\(Int64(expSeconds)),\"iat\":\(Int64(iat)),\"orig_iat\":\(Int64(origIat))}"
    return authFlowBase64Url(header) + "." + authFlowBase64Url(payload) + ".sig"
}


private func authFlowBase64Url(_ text: String) -> String {
    return Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}


final class ImpulseAuthFlowTests: XCTestCase {
    /// `auth.authorization` with a `userEmpty` of id 3, session token A and refresh token B.
    private static let authorizationHex: String = "0a0c 2a040a020803 320141 3a0142"
    /// `auth.authorizationSignUpRequired` with no fields.
    private static let signUpRequiredHex: String = "1200"
    /// The authorization of the user but without any token.
    private static let tokenlessAuthorizationHex: String = "0a062a040a020803"


    private struct Fixture {
        let mapping: ImpulseMapping
        let pool: AuthFlowPoolCarrier
        let identityStore: AuthFlowIdentityStore
        let identity: ImpulseIdentityManager
        let storage: AuthFlowStorage
        let socket: AuthFlowSocket
        let differences: AuthFlowDifferences
        let realtime: ImpulseRealtime
        let requester: AuthFlowRequester
        let flow: ImpulseAuthFlow
    }


    private func makeFixture() throws -> Fixture {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let pool: AuthFlowPoolCarrier = AuthFlowPoolCarrier()
        let identityStore: AuthFlowIdentityStore = AuthFlowIdentityStore()
        let identity: ImpulseIdentityManager = ImpulseIdentityManager(
            poolCarrier: pool,
            store: identityStore,
            clock: AuthFlowClock(),
            scheduler: AuthFlowScheduler(),
            apiId: 4
        )
        let storage: AuthFlowStorage = AuthFlowStorage()
        let tokens: ImpulseTokens = ImpulseTokens(
            storage: storage,
            transport: AuthFlowRefreshTransport(),
            clock: { () -> Date in
                return Date(timeIntervalSince1970: 1_000_000)
            }
        )
        let socket: AuthFlowSocket = AuthFlowSocket()
        let differences: AuthFlowDifferences = AuthFlowDifferences()
        let realtime: ImpulseRealtime = ImpulseRealtime(
            mapping: mapping,
            socket: socket,
            differenceHandler: { (request: ImpulseDifferenceRequest) -> Void in
                differences.record(request)
            },
            updateHandler: { (updates: ImpulseRealtimeUpdates) -> Void in
            }
        )
        let requester: AuthFlowRequester = AuthFlowRequester()
        let flow: ImpulseAuthFlow = ImpulseAuthFlow(
            identity: identity,
            tokens: tokens,
            storage: storage,
            realtime: realtime,
            requester: requester,
            transcoder: transcoder,
            mapping: mapping
        )
        return Fixture(
            mapping: mapping,
            pool: pool,
            identityStore: identityStore,
            identity: identity,
            storage: storage,
            socket: socket,
            differences: differences,
            realtime: realtime,
            requester: requester,
            flow: flow
        )
    }


    private func bytes(hex: String) throws -> [UInt8] {
        let compact: String = hex.filter { (character: Character) -> Bool in
            return !character.isWhitespace
        }
        var result: [UInt8] = []
        var index: String.Index = compact.startIndex
        while index < compact.endIndex {
            let next: String.Index = compact.index(index, offsetBy: 2)
            let value: UInt8 = try XCTUnwrap(UInt8(compact[index..<next], radix: 16))
            result.append(value)
            index = next
        }
        return result
    }


    private func signInRequest(_ mapping: ImpulseMapping) throws -> ImpulseEncodedRequest {
        let method: ImpulseMappingMethod = try XCTUnwrap(mapping.method(name: "auth.signIn"))
        return ImpulseEncodedRequest(
            methodId: method.id,
            method: "auth.signIn",
            path: "",
            proto: [],
            takeoutId: nil
        )
    }


    private func signUpRequest(_ mapping: ImpulseMapping) throws -> ImpulseEncodedRequest {
        let method: ImpulseMappingMethod = try XCTUnwrap(mapping.method(name: "auth.signUp"))
        return ImpulseEncodedRequest(
            methodId: method.id,
            method: "auth.signUp",
            path: "",
            proto: [],
            takeoutId: nil
        )
    }


    /// Begins a login and signs in with the golden authorization, leaving the fixture signed in as user 3.
    private func signIn(_ fixture: Fixture) async throws {
        try await fixture.flow.beginLogin()
        fixture.requester.replies = [.success(try bytes(hex: ImpulseAuthFlowTests.authorizationHex))]
        let result: ImpulseLoginResult = try await fixture.flow.completeLogin(try signInRequest(fixture.mapping))
        XCTAssertEqual(result, .signedIn(userId: 3))
    }


    func testBeginLoginMintsIdentityAndCarriesItOnUpdateSocket() async throws {
        let fixture: Fixture = try makeFixture()

        try await fixture.flow.beginLogin()

        XCTAssertEqual(fixture.pool.mintCount, 1)
        XCTAssertEqual(fixture.identityStore.values[ImpulseIdentityRules.storageKey], fixture.pool.issued.first)
        XCTAssertEqual(
            fixture.socket.calls,
            ["disconnect", "token " + fixture.pool.issued[0], "connect"]
        )
    }


    func testSignInCapturesTokensDiscardsIdentityAndRekeysToSession() async throws {
        let fixture: Fixture = try makeFixture()
        try await fixture.flow.beginLogin()
        fixture.socket.calls.removeAll()
        fixture.requester.replies = [.success(try bytes(hex: ImpulseAuthFlowTests.authorizationHex))]

        let result: ImpulseLoginResult = try await fixture.flow.completeLogin(try signInRequest(fixture.mapping))

        XCTAssertEqual(result, .signedIn(userId: 3))
        XCTAssertEqual(
            fixture.storage.stored,
            ImpulseSessionTokens(accessToken: "A", refreshToken: "B", userId: 3)
        )
        XCTAssertNil(fixture.identityStore.values[ImpulseIdentityRules.storageKey])
        XCTAssertEqual(fixture.requester.gateStates, [true])
        XCTAssertEqual(
            fixture.socket.calls,
            ["disconnect", "token A", "connect", "subscribe user:3 true true"]
        )
    }


    func testSignInSubscribesUserLaneAndFreshSubscribeRunsDifference() async throws {
        let fixture: Fixture = try makeFixture()
        try await signIn(fixture)

        fixture.socket.listener?.handleSubscribed(channel: "user:3", recovered: false, wasRecovering: false)

        XCTAssertEqual(fixture.differences.requests, [.account(.subscribeNotRecovered)])
    }


    func testSignUpAuthorizationEndsLoginAsSignInDoes() async throws {
        let fixture: Fixture = try makeFixture()
        try await fixture.flow.beginLogin()
        fixture.socket.calls.removeAll()
        fixture.requester.replies = [.success(try bytes(hex: ImpulseAuthFlowTests.authorizationHex))]

        let result: ImpulseLoginResult = try await fixture.flow.completeLogin(try signUpRequest(fixture.mapping))

        XCTAssertEqual(result, .signedIn(userId: 3))
        XCTAssertEqual(
            fixture.storage.stored,
            ImpulseSessionTokens(accessToken: "A", refreshToken: "B", userId: 3)
        )
        XCTAssertEqual(fixture.requester.sentMethods, ["auth.signUp"])
        XCTAssertEqual(fixture.requester.lastOptions?.withoutLogin, true)
        XCTAssertEqual(fixture.requester.gateStates, [true])
        XCTAssertEqual(
            fixture.socket.calls,
            ["disconnect", "token A", "connect", "subscribe user:3 true true"]
        )
    }


    func testSignInSendsAuthCallsWithoutLoginAndAcceptsSignUpRequired() async throws {
        let fixture: Fixture = try makeFixture()
        try await fixture.flow.beginLogin()
        fixture.requester.replies = [.success(try bytes(hex: ImpulseAuthFlowTests.signUpRequiredHex))]

        let result: ImpulseLoginResult = try await fixture.flow.completeLogin(try signInRequest(fixture.mapping))

        XCTAssertEqual(result, .signUpRequired)
        XCTAssertNil(fixture.storage.stored)
        XCTAssertNotNil(fixture.identityStore.values[ImpulseIdentityRules.storageKey])
        XCTAssertEqual(fixture.requester.gateStates, [])
        XCTAssertEqual(fixture.requester.lastOptions?.withoutLogin, true)
        XCTAssertEqual(fixture.requester.sentMethods, ["auth.signIn"])
    }


    func testSendLoginCallUsesIdentitySocketWithoutLogin() async throws {
        let fixture: Fixture = try makeFixture()
        let method: ImpulseMappingMethod = try XCTUnwrap(fixture.mapping.method(name: "auth.sendCode"))
        let request: ImpulseEncodedRequest = ImpulseEncodedRequest(
            methodId: method.id,
            method: "auth.sendCode",
            path: "",
            proto: [],
            takeoutId: nil
        )
        fixture.requester.replies = [.failure(.canceled)]

        let settled: Result<[UInt8], ImpulseRequestFailure> = await fixture.flow.sendLoginCall(request)

        XCTAssertEqual(settled, .failure(.canceled))
        XCTAssertEqual(fixture.requester.sentMethods, ["auth.sendCode"])
        XCTAssertEqual(fixture.requester.lastOptions?.withoutLogin, true)
    }


    func testCompleteLoginRejectsMethodThatDoesNotEndLogin() async throws {
        let fixture: Fixture = try makeFixture()
        let request: ImpulseEncodedRequest = ImpulseEncodedRequest(
            methodId: 0,
            method: "auth.sendCode",
            path: "",
            proto: [],
            takeoutId: nil
        )

        do {
            _ = try await fixture.flow.completeLogin(request)
            XCTFail("a sendCode must not end a login")
        } catch let error as ImpulseAuthError {
            XCTAssertEqual(error, .unexpectedMethod("auth.sendCode"))
        }
        XCTAssertTrue(fixture.requester.sentMethods.isEmpty)
    }


    func testRequestFailureIsReportedAndKeepsLoginClosed() async throws {
        let fixture: Fixture = try makeFixture()
        let failure: ImpulseRequestFailure = .network(ImpulseCarrierFailure(sdkCode: 1, appCode: 0, appType: "", metadata: [:]))
        fixture.requester.replies = [.failure(failure)]

        do {
            _ = try await fixture.flow.completeLogin(try signInRequest(fixture.mapping))
            XCTFail("a failed request must not end a login")
        } catch let error as ImpulseAuthError {
            XCTAssertEqual(error, .request(failure))
        }
        XCTAssertNil(fixture.storage.stored)
        XCTAssertTrue(fixture.requester.gateStates.isEmpty)
    }


    func testAuthorizationWithoutTokensIsRejected() async throws {
        let fixture: Fixture = try makeFixture()
        try await fixture.flow.beginLogin()
        fixture.requester.replies = [.success(try bytes(hex: ImpulseAuthFlowTests.tokenlessAuthorizationHex))]

        do {
            _ = try await fixture.flow.completeLogin(try signInRequest(fixture.mapping))
            XCTFail("an authorization without tokens must not end a login")
        } catch is ImpulseAuthError {
        }
        XCTAssertNil(fixture.storage.stored)
        XCTAssertNotNil(fixture.identityStore.values[ImpulseIdentityRules.storageKey])
        XCTAssertTrue(fixture.requester.gateStates.isEmpty)
    }


    func testSignOutDiscardsSessionAndIdentityAndRekeysToFreshIdentity() async throws {
        let fixture: Fixture = try makeFixture()
        try await signIn(fixture)
        fixture.socket.calls.removeAll()
        let storage: AuthFlowStorage = fixture.storage
        var sessionAtLogOut: Bool = false
        fixture.requester.onExecute = { (method: String) -> Void in
            sessionAtLogOut = storage.stored != nil
        }
        fixture.requester.replies = [.success([])]

        try await fixture.flow.signOut()

        XCTAssertEqual(fixture.requester.sentMethods, ["auth.signIn", "auth.logOut"])
        XCTAssertTrue(sessionAtLogOut)
        XCTAssertEqual(fixture.requester.lastOptions, ImpulseRequestOptions())
        XCTAssertNil(fixture.storage.stored)
        XCTAssertEqual(fixture.pool.mintCount, 2)
        XCTAssertEqual(fixture.identityStore.values[ImpulseIdentityRules.storageKey], fixture.pool.issued[1])
        XCTAssertEqual(fixture.requester.gateStates, [true, false])
        XCTAssertEqual(
            fixture.socket.calls,
            ["unsubscribe user:3", "disconnect", "token " + fixture.pool.issued[1], "connect"]
        )
    }


    func testFailingLogOutStillDiscardsSessionAndRekeysToFreshIdentity() async throws {
        let fixture: Fixture = try makeFixture()
        try await signIn(fixture)
        fixture.socket.calls.removeAll()
        let failure: ImpulseRequestFailure = .network(ImpulseCarrierFailure(sdkCode: 1, appCode: 0, appType: "", metadata: [:]))
        fixture.requester.replies = [.failure(failure)]

        try await fixture.flow.signOut()

        XCTAssertEqual(fixture.requester.sentMethods, ["auth.signIn", "auth.logOut"])
        XCTAssertNil(fixture.storage.stored)
        XCTAssertEqual(fixture.pool.mintCount, 2)
        XCTAssertEqual(fixture.identityStore.values[ImpulseIdentityRules.storageKey], fixture.pool.issued[1])
        XCTAssertEqual(fixture.requester.gateStates, [true, false])
        XCTAssertEqual(
            fixture.socket.calls,
            ["unsubscribe user:3", "disconnect", "token " + fixture.pool.issued[1], "connect"]
        )
    }


    func testSignOutWithoutSessionDoesNotCallLogOut() async throws {
        let fixture: Fixture = try makeFixture()

        try await fixture.flow.signOut()

        XCTAssertTrue(fixture.requester.sentMethods.isEmpty)
        XCTAssertNil(fixture.storage.stored)
        XCTAssertEqual(fixture.requester.gateStates, [false])
    }
}
