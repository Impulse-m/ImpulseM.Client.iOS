import Foundation
import XCTest
@testable import ImpulseTransport


/// The authorization golden of the sign-in tests: user 3, session token A, refresh token B, as a proto `auth.authorization`.
private let liveInstallAuthorizationHex: String = "0a0c2a040a0208033201413a0142"
/// The reply of `auth.checkPassword`: the authorization itself.
private let liveInstallCheckPasswordHex: String = liveInstallAuthorizationHex
/// The reply of `auth.importLoginToken` that succeeded: the arm `auth.loginTokenSuccess` (field 3) carries the
/// authorization in its field 1.
private let liveInstallLoginTokenSuccessHex: String = "1a100a0e" + liveInstallAuthorizationHex
/// An authorization with no token: the reply carries no session, so nothing is installed.
private let liveInstallTokenlessHex: String = "0a062a040a020803"
/// The cancelled code of the SDK, which the carrier answers with once its queued replies are used up.
private let liveInstallCancelledCode: Int = 17


private func liveInstallBytes(hex: String) throws -> [UInt8] {
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


/// The record of the events of one test, in order. The socket and the update carrier write to it.
private final class LiveInstallEvents: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var entries: [String] = []


    func append(_ entry: String) {
        self.lock.lock()
        self.entries.append(entry)
        self.lock.unlock()
    }


    func all() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries
    }
}


/// The socket of the realtime client. It records the rekeys and the subscriptions in the order they happen.
private final class LiveInstallSocket: ImpulseRealtimeSocket {
    var listener: (any ImpulseRealtimeSocketListener)? = nil
    private let events: LiveInstallEvents


    init(events: LiveInstallEvents) {
        self.events = events
    }


    func connect() {
        self.events.append("connect")
    }


    func disconnect() {
        self.events.append("disconnect")
    }


    func setConnectionToken(_ token: String) {
        self.events.append("token " + token)
    }


    func subscribe(
        channel: String,
        positioned: Bool,
        recoverable: Bool
    ) {
        self.events.append("subscribe \(channel) \(positioned) \(recoverable)")
    }


    func unsubscribe(channel: String) {
        self.events.append("unsubscribe " + channel)
    }
}


/// The update carrier of the session. It records each send and answers with the queued replies, then with the default reply.
private final class LiveInstallCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let events: LiveInstallEvents
    private var replies: [Result<[UInt8], ImpulseCarrierFailure>]
    private let defaultReply: Result<[UInt8], ImpulseCarrierFailure>


    init(
        events: LiveInstallEvents,
        replies: [Result<[UInt8], ImpulseCarrierFailure>],
        defaultReply: Result<[UInt8], ImpulseCarrierFailure>
    ) {
        self.events = events
        self.replies = replies
        self.defaultReply = defaultReply
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.events.append("send " + method)
        return self.nextReply()
    }


    private func nextReply() -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.replies.isEmpty {
            return self.defaultReply
        }
        return self.replies.removeFirst()
    }
}


private final class LiveInstallStorage: ImpulseSessionStorage, @unchecked Sendable {
    private(set) var stored: ImpulseSessionTokens? = nil


    func load() -> ImpulseSessionTokens? {
        return self.stored
    }


    func save(_ tokens: ImpulseSessionTokens) {
        self.stored = tokens
    }


    func clear() {
        self.stored = nil
    }
}


private struct LiveInstallRefreshTransport: ImpulseRefreshTransport {
    func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply {
        return .failure(ImpulseCarrierFailure(sdkCode: liveInstallCancelledCode, appCode: 0, appType: "", metadata: [:]))
    }
}


private final class LiveInstallIdentityStore: ImpulseIdentityStore, @unchecked Sendable {
    func string(forKey key: String) -> String? {
        return nil
    }


    func setString(
        _ value: String,
        forKey key: String
    ) {
    }


    func removeValue(forKey key: String) {
    }
}


private struct LiveInstallIdentityCarrier: ImpulseIdentityCarrier {
    func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String {
        throw ImpulseIdentityError.emptyReply
    }
}


/// Everything a live-path test needs: a session of the main role whose login reply path installs into the stores and the socket.
private struct LiveInstallFixture {
    let mapping: ImpulseMapping
    let events: LiveInstallEvents
    let storage: LiveInstallStorage
    let socket: LiveInstallSocket
    let session: ImpulseNetworkSession
}


private func makeLiveInstallFixture(
    replies: [Result<[UInt8], ImpulseCarrierFailure>]
) throws -> LiveInstallFixture {
    let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
    let events: LiveInstallEvents = LiveInstallEvents()
    let storage: LiveInstallStorage = LiveInstallStorage()
    let tokens: ImpulseTokens = ImpulseTokens(storage: storage, transport: LiveInstallRefreshTransport())
    let socket: LiveInstallSocket = LiveInstallSocket(events: events)
    let realtime: ImpulseRealtime = ImpulseRealtime(
        mapping: mapping,
        socket: socket,
        differenceHandler: { (request: ImpulseDifferenceRequest) -> Void in
        },
        updateHandler: { (updates: ImpulseRealtimeUpdates) -> Void in
        }
    )
    let identity: ImpulseIdentityManager = ImpulseIdentityManager(
        poolCarrier: LiveInstallIdentityCarrier(),
        store: LiveInstallIdentityStore(),
        clock: ImpulseSystemClock(),
        scheduler: ImpulseTaskScheduler(),
        apiId: 4
    )
    let loginGate: ImpulseLoginGate = ImpulseLoginGate(isOpen: false)
    let installer: ImpulseSessionInstaller = ImpulseSessionInstaller(
        identity: identity,
        tokens: tokens,
        realtime: realtime,
        mapping: mapping,
        setSignedIn: { (signedIn: Bool) -> Void in
            loginGate.setOpen(signedIn)
        },
        credentials: nil,
        declarer: nil
    )
    let carrier: LiveInstallCarrier = LiveInstallCarrier(
        events: events,
        replies: replies,
        defaultReply: .failure(ImpulseCarrierFailure(sdkCode: liveInstallCancelledCode, appCode: 0, appType: "", metadata: [:]))
    )
    let session: ImpulseNetworkSession = ImpulseNetworkSession(
        datacenterId: 4,
        role: .main,
        transcoder: ImpulseTranscoder(mapping: mapping),
        session: tokens,
        updateCarrier: carrier,
        mediaCarrier: carrier,
        poolCarrier: carrier,
        declarations: nil,
        signedIn: false,
        delegate: nil,
        loginGate: loginGate,
        sessionInstaller: installer
    )
    return LiveInstallFixture(
        mapping: mapping,
        events: events,
        storage: storage,
        socket: socket,
        session: session
    )
}


/// The bare TL of a mapped method, with its parameters synthesized the way the round-trip tests do.
private func liveInstallMethodTl(
    mapping: ImpulseMapping,
    name: String
) throws -> [UInt8] {
    let method: ImpulseMappingMethod = try XCTUnwrap(mapping.method(name: name))
    return try ImpulseTlSynth(mapping: mapping).methodTl(method: method, allFlags: false)
}


/// Sends one call with the login flag set, as the login calls of the engine are sent, and waits for its completion.
private func liveInstallPerform(
    session: ImpulseNetworkSession,
    tl: [UInt8],
    options: ImpulseRequestOptions = ImpulseRequestOptions(withoutLogin: true)
) async -> Result<ImpulseNetworkResponse, ImpulseRequestFailure> {
    return await withCheckedContinuation { (continuation: CheckedContinuation<Result<ImpulseNetworkResponse, ImpulseRequestFailure>, Never>) -> Void in
        let request: ImpulseNetworkRequest = ImpulseNetworkRequest(
            tl: tl,
            options: options,
            parse: { (bytes: [UInt8]) -> Any? in
                return bytes
            },
            completed: { (result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void in
                continuation.resume(returning: result)
            }
        )
        _ = session.add(request)
    }
}


final class ImpulseSessionInstallTests: XCTestCase {
    func testCheckPasswordReplyInstallsTheSessionBeforeTheReplyGoesOn() async throws {
        let fixture: LiveInstallFixture = try makeLiveInstallFixture(
            replies: [.success(try liveInstallBytes(hex: liveInstallCheckPasswordHex))]
        )
        let tl: [UInt8] = try liveInstallMethodTl(mapping: fixture.mapping, name: "auth.checkPassword")

        let result: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await liveInstallPerform(
            session: fixture.session,
            tl: tl
        )

        XCTAssertNotNil(try result.get())
        XCTAssertEqual(
            fixture.storage.stored,
            ImpulseSessionTokens(accessToken: "A", refreshToken: "B", userId: 3)
        )
        XCTAssertEqual(
            fixture.events.all(),
            [
                "send auth.checkPassword",
                "disconnect",
                "token A",
                "connect",
                "subscribe user:3 true true",
            ]
        )
    }


    func testImportLoginTokenSuccessInstallsTheSession() async throws {
        let fixture: LiveInstallFixture = try makeLiveInstallFixture(
            replies: [.success(try liveInstallBytes(hex: liveInstallLoginTokenSuccessHex))]
        )
        let tl: [UInt8] = try liveInstallMethodTl(mapping: fixture.mapping, name: "auth.importLoginToken")

        let result: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await liveInstallPerform(
            session: fixture.session,
            tl: tl
        )

        XCTAssertNotNil(try result.get())
        XCTAssertEqual(
            fixture.storage.stored,
            ImpulseSessionTokens(accessToken: "A", refreshToken: "B", userId: 3)
        )
        XCTAssertEqual(
            fixture.events.all(),
            [
                "send auth.importLoginToken",
                "disconnect",
                "token A",
                "connect",
                "subscribe user:3 true true",
            ]
        )
    }


    /// A session call made before the login waits for the install: nothing is sent, then the socket is rekeyed to the access
    /// token, and only after that the call goes out.
    func testSessionCallWaitsForTheInstallAndIsSentAfterTheRekey() async throws {
        let fixture: LiveInstallFixture = try makeLiveInstallFixture(
            replies: [.success(try liveInstallBytes(hex: liveInstallLoginTokenSuccessHex))]
        )
        let resetTl: [UInt8] = try liveInstallMethodTl(mapping: fixture.mapping, name: "auth.resetAuthorizations")
        let loginTl: [UInt8] = try liveInstallMethodTl(mapping: fixture.mapping, name: "auth.importLoginToken")

        let waiting: Task<Result<ImpulseNetworkResponse, ImpulseRequestFailure>, Never> = Task {
            return await liveInstallPerform(
                session: fixture.session,
                tl: resetTl,
                options: ImpulseRequestOptions()
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.events.all(), [])

        _ = await liveInstallPerform(session: fixture.session, tl: loginTl)
        _ = await waiting.value

        XCTAssertEqual(
            fixture.events.all(),
            [
                "send auth.importLoginToken",
                "disconnect",
                "token A",
                "connect",
                "subscribe user:3 true true",
                "send auth.resetAuthorizations",
            ]
        )
    }


    func testReplyWithoutTokensInstallsNothing() async throws {
        let fixture: LiveInstallFixture = try makeLiveInstallFixture(
            replies: [.success(try liveInstallBytes(hex: liveInstallTokenlessHex))]
        )
        let tl: [UInt8] = try liveInstallMethodTl(mapping: fixture.mapping, name: "auth.checkPassword")

        _ = await liveInstallPerform(session: fixture.session, tl: tl)

        XCTAssertNil(fixture.storage.stored)
        XCTAssertEqual(fixture.events.all(), ["send auth.checkPassword"])
    }
}
