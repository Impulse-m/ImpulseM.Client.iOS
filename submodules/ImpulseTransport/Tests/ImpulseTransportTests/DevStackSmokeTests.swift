import Foundation
import SwiftCentrifuge
import XCTest
@testable import ImpulseTransport


private let devStackSkipMessage: String = "Set IMPULSEM_DEV_STACK=1 and IMPULSEM_DEV_STACK_BASE_URL to run the dev-stack smoke checks"


/// The settings of the dev-stack run, read from the environment. The run is opt-in: every test skips unless
/// `IMPULSEM_DEV_STACK` is `1` and `IMPULSEM_DEV_STACK_BASE_URL` names the stand. `IMPULSEM_DEV_STACK_PHONE` names
/// the phone number that `auth.sendCode` is asked for.
private struct DevStackSettings: Sendable {
    static let enableVariable: String = "IMPULSEM_DEV_STACK"
    static let baseUrlVariable: String = "IMPULSEM_DEV_STACK_BASE_URL"
    static let phoneVariable: String = "IMPULSEM_DEV_STACK_PHONE"
    static let defaultPhone: String = "+15555550100"
    /// The api id of the desktop application.
    static let apiId: Int32 = 4
    /// The dev application hash of the desktop application.
    static let apiHash: String = "21f053db6ffe90fd4519db7b90249ec9"
    static let langPack: String = "macos"
    static let langCode: String = "en"
    static let connectWaitSeconds: TimeInterval = 15
    static let connectPollNanoseconds: UInt64 = 100_000_000
    static let requestDeadlineSeconds: TimeInterval = 20

    let baseUrl: String
    let phone: String


    static var isEnabled: Bool {
        let environment: [String: String] = ProcessInfo.processInfo.environment
        guard environment[DevStackSettings.enableVariable] == "1" else {
            return false
        }
        return !DevStackSettings.value(of: DevStackSettings.baseUrlVariable, fallback: "", in: environment).isEmpty
    }


    static func fromEnvironment() -> DevStackSettings {
        let environment: [String: String] = ProcessInfo.processInfo.environment
        let baseUrl: String = DevStackSettings.value(
            of: DevStackSettings.baseUrlVariable,
            fallback: "",
            in: environment
        )
        let phone: String = DevStackSettings.value(
            of: DevStackSettings.phoneVariable,
            fallback: DevStackSettings.defaultPhone,
            in: environment
        )
        return DevStackSettings(baseUrl: baseUrl, phone: phone)
    }


    /// The value of a variable, or the fallback when the variable is absent or empty. CI passes empty variables through.
    private static func value(
        of name: String,
        fallback: String,
        in environment: [String: String]
    ) -> String {
        guard let value: String = environment[name], !value.isEmpty else {
            return fallback
        }
        return value
    }
}


private enum DevStackSmokeError: Error {
    case notConnected
    case missingMethod(String)
    case missingConstructor(String)
    case requestFailed(String)
    case noSession
}


/// Records that the update socket connected. The SDK calls it on its own queue.
private final class DevStackClientDelegate: CentrifugeClientDelegate, @unchecked Sendable {
    var isConnected: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.connected
    }


    private let lock: NSLock = NSLock()
    private var connected: Bool = false


    func onConnected(
        _ client: CentrifugeClient,
        _ event: CentrifugeConnectedEvent
    ) {
        self.lock.lock()
        self.connected = true
        self.lock.unlock()
    }
}


/// An in-memory identity store. The smoke run keeps nothing across runs.
private final class DevStackIdentityStore: ImpulseIdentityStore, @unchecked Sendable {
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


/// A session that is never stored: the smoke run is signed out, so the login calls are sent without a user.
private struct DevStackNoSession: ImpulseRequestSession {
    func hasSession() async -> Bool {
        return false
    }


    func needsProactiveRefresh() async -> Bool {
        return false
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        throw DevStackSmokeError.noSession
    }
}


/// The transport of one smoke run, built the way the app builds it: a pool that mints the connection identity, an
/// update socket that carries the identity, the declaration of the connection, and the request service that sends the
/// calls. Every wait has its own deadline: the pool calls and the identity mint 30 s, the connect wait
/// `DevStackSettings.connectWaitSeconds`, the declaration 10 s and each request `DevStackSettings.requestDeadlineSeconds`.
private final class DevStackFixture: @unchecked Sendable {
    let settings: DevStackSettings
    let mapping: ImpulseMapping
    let transcoder: ImpulseTranscoder
    let identityToken: String
    private let pool: ImpulsePoolCarrier
    private let client: CentrifugeClient
    private let clientDelegate: DevStackClientDelegate
    private let declarer: ImpulseConnectionDeclarer
    private let service: ImpulseRequestService


    private init(
        settings: DevStackSettings,
        mapping: ImpulseMapping,
        transcoder: ImpulseTranscoder,
        identityToken: String,
        pool: ImpulsePoolCarrier,
        client: CentrifugeClient,
        clientDelegate: DevStackClientDelegate,
        declarer: ImpulseConnectionDeclarer,
        service: ImpulseRequestService
    ) {
        self.settings = settings
        self.mapping = mapping
        self.transcoder = transcoder
        self.identityToken = identityToken
        self.pool = pool
        self.client = client
        self.clientDelegate = clientDelegate
        self.declarer = declarer
        self.service = service
    }


    /// Starts the pool, mints the connection identity on it, connects the update socket with that identity and declares
    /// the connection on the socket.
    static func make(settings: DevStackSettings) async throws -> DevStackFixture {
        let endpoints: ImpulseEndpoints = try ImpulseEndpoints(baseUrl: settings.baseUrl)
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)

        let pool: ImpulsePoolCarrier = try ImpulsePoolCarrier(
            endpoint: endpoints.poolUrl(),
            identityRenewal: DevStackFixture.noRenewal
        )
        pool.start()
        let poolRequests: ImpulsePoolRequestCarrier = ImpulsePoolRequestCarrier(pool: pool)

        let identityManager: ImpulseIdentityManager = ImpulseIdentityManager(
            poolCarrier: ImpulsePoolIdentityCarrier(carrier: poolRequests),
            store: DevStackIdentityStore(),
            clock: ImpulseSystemClock(),
            scheduler: ImpulseTaskScheduler(),
            apiId: DevStackSettings.apiId
        )
        let identityToken: String = try await identityManager.obtain()

        let credentials: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()
        credentials.setIdentityToken(identityToken)

        let clientDelegate: DevStackClientDelegate = DevStackClientDelegate()
        var config: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.defaultClientConfig()
        config.token = identityToken
        let client: CentrifugeClient = ImpulseUpdateSocketCarrier.makeClient(
            endpoint: endpoints.realtimeUrl(),
            config: config,
            delegate: clientDelegate
        )
        let updateCarrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(client: client)
        client.connect()
        try await DevStackFixture.waitForConnection(clientDelegate)

        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: updateCarrier,
            credentials: credentials
        )
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: DevStackSettings.apiId,
            deviceModel: "Mac",
            systemVersion: "macOS",
            appVersion: "smoke",
            systemLangCode: DevStackSettings.langCode,
            langPack: DevStackSettings.langPack,
            langCode: DevStackSettings.langCode
        )
        await declarer.setDeclaration(declaration)

        let service: ImpulseRequestService = ImpulseRequestService(
            session: DevStackNoSession(),
            updateCarrier: updateCarrier,
            mediaCarrier: updateCarrier,
            poolCarrier: poolRequests,
            declarations: declarer,
            signedIn: false,
            onAuthorizationRequired: {},
            clock: ImpulseSystemRequestClock()
        )

        return DevStackFixture(
            settings: settings,
            mapping: mapping,
            transcoder: transcoder,
            identityToken: identityToken,
            pool: pool,
            client: client,
            clientDelegate: clientDelegate,
            declarer: declarer,
            service: service
        )
    }


    /// The TL writer of a method, holding the method id. The caller appends the arguments.
    func methodWriter(_ name: String) throws -> ImpulseTlWriter {
        guard let method: ImpulseMappingMethod = self.mapping.method(name: name) else {
            throw DevStackSmokeError.missingMethod(name)
        }
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: method.id))
        return writer
    }


    /// The constructor id of the first constructor of a type.
    func constructorId(ofType typeName: String) throws -> UInt32 {
        guard let constructor: ImpulseMappingConstructor = self.mapping.constructors(ofType: typeName).first else {
            throw DevStackSmokeError.missingConstructor(typeName)
        }
        return constructor.id
    }


    /// The constructor ids of every constructor of a type.
    func constructorIds(ofType typeName: String) -> Set<UInt32> {
        let ids: [UInt32] = self.mapping.constructors(ofType: typeName).map { (constructor: ImpulseMappingConstructor) -> UInt32 in
            return constructor.id
        }
        return Set(ids)
    }


    /// Sends one TL request on the update socket, through the request service, and returns the TL reply.
    func call(
        method: String,
        tl: [UInt8]
    ) async throws -> [UInt8] {
        let encoded: ImpulseEncodedRequest = try self.transcoder.encodeRequest(tl: tl)
        let options: ImpulseRequestOptions = ImpulseRequestOptions(
            withoutLogin: true,
            totalDeadlineSeconds: DevStackSettings.requestDeadlineSeconds
        )
        let settled: Result<[UInt8], ImpulseRequestFailure> = await self.service.execute(
            request: encoded,
            options: options
        )
        switch settled {
        case .success(let proto):
            return try self.transcoder.decodeResult(
                methodId: encoded.methodId,
                proto: proto,
                capture: nil
            )

        case .failure(let failure):
            throw DevStackSmokeError.requestFailed(method + ": " + String(describing: failure))
        }
    }


    /// Disconnects the update socket and stops the pool.
    func close() {
        self.client.disconnect()
        self.pool.stop()
    }


    /// The subject of a connection identity: `i:` followed by 32 lower-case hex characters.
    static func isConnectionIdentitySubject(_ subject: String) -> Bool {
        let prefix: String = "i:"
        guard subject.hasPrefix(prefix) else {
            return false
        }
        let hex: Substring = subject.dropFirst(prefix.count)
        let allowed: Set<Character> = Set("0123456789abcdef")
        guard hex.count == 32 else {
            return false
        }
        return hex.allSatisfy { (character: Character) -> Bool in
            return allowed.contains(character)
        }
    }


    /// The constructor id at the start of a TL object, or nil when the object is shorter than one word.
    static func leadingConstructorId(of tl: [UInt8]) -> UInt32? {
        guard tl.count >= 4 else {
            return nil
        }
        return DevStackFixture.readWord(tl, at: 0)
    }


    /// True when the TL bytes hold a vector of `elementId` elements with at least one element. TL words are 4-byte
    /// aligned, so the scan visits every word boundary.
    static func containsNonEmptyVector(
        of elementId: UInt32,
        in tl: [UInt8]
    ) -> Bool {
        var offset: Int = 0
        while offset + 12 <= tl.count {
            let word: UInt32 = DevStackFixture.readWord(tl, at: offset)
            if word == ImpulseTlConstants.vector {
                let count: UInt32 = DevStackFixture.readWord(tl, at: offset + 4)
                let first: UInt32 = DevStackFixture.readWord(tl, at: offset + 8)
                if count > 0 && first == elementId {
                    return true
                }
            }
            offset += 4
        }
        return false
    }


    private static let noRenewal: ImpulsePoolIdentityRenewal = { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
        completion(.success(()))
    }


    /// Reads a little-endian 32-bit word of the TL bytes.
    private static func readWord(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32 {
        let byte0: UInt32 = UInt32(bytes[offset])
        let byte1: UInt32 = UInt32(bytes[offset + 1]) << 8
        let byte2: UInt32 = UInt32(bytes[offset + 2]) << 16
        let byte3: UInt32 = UInt32(bytes[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }


    private static func waitForConnection(_ delegate: DevStackClientDelegate) async throws {
        let deadline: Date = Date().addingTimeInterval(DevStackSettings.connectWaitSeconds)
        while !delegate.isConnected {
            if Date() >= deadline {
                throw DevStackSmokeError.notConnected
            }
            try await Task.sleep(nanoseconds: DevStackSettings.connectPollNanoseconds)
        }
    }
}


/// Runs the login-path checks against a live stand. They are skipped unless `IMPULSEM_DEV_STACK=1`, so the default test
/// run never reaches the network.
final class DevStackSmokeTests: XCTestCase {
    func testIdentityMintReturnsConnectionIdentity() async throws {
        try XCTSkipUnless(DevStackSettings.isEnabled, devStackSkipMessage)
        let fixture: DevStackFixture = try await DevStackFixture.make(settings: DevStackSettings.fromEnvironment())
        defer {
            fixture.close()
        }

        guard let claims: ImpulseIdentityClaims = ImpulseIdentityClaims.parse(token: fixture.identityToken) else {
            XCTFail("the minted connection identity is not a readable JWT")
            return
        }
        XCTAssertTrue(
            DevStackFixture.isConnectionIdentitySubject(claims.sub),
            "the identity subject is not i: followed by 32 hex characters"
        )
    }


    func testHelpGetConfigReturnsDcOptions() async throws {
        try XCTSkipUnless(DevStackSettings.isEnabled, devStackSkipMessage)
        let fixture: DevStackFixture = try await DevStackFixture.make(settings: DevStackSettings.fromEnvironment())
        defer {
            fixture.close()
        }

        let writer: ImpulseTlWriter = try fixture.methodWriter("help.getConfig")
        let reply: [UInt8] = try await fixture.call(method: "help.getConfig", tl: writer.toByteArray())
        let configId: UInt32 = try fixture.constructorId(ofType: "Config")
        let dcOptionId: UInt32 = try fixture.constructorId(ofType: "DcOption")

        XCTAssertEqual(DevStackFixture.leadingConstructorId(of: reply), configId)
        XCTAssertTrue(
            DevStackFixture.containsNonEmptyVector(of: dcOptionId, in: reply),
            "help.getConfig carries no dc_options"
        )
    }


    func testAuthSendCodeOnUpdateSocket() async throws {
        try XCTSkipUnless(DevStackSettings.isEnabled, devStackSkipMessage)
        let fixture: DevStackFixture = try await DevStackFixture.make(settings: DevStackSettings.fromEnvironment())
        defer {
            fixture.close()
        }

        let codeSettingsId: UInt32 = try fixture.constructorId(ofType: "CodeSettings")
        var writer: ImpulseTlWriter = try fixture.methodWriter("auth.sendCode")
        try writer.writeString(value: fixture.settings.phone)
        writer.writeInt32(value: DevStackSettings.apiId)
        try writer.writeString(value: DevStackSettings.apiHash)
        writer.writeInt32(value: Int32(bitPattern: codeSettingsId))
        writer.writeInt32(value: 0)

        let reply: [UInt8] = try await fixture.call(method: "auth.sendCode", tl: writer.toByteArray())
        let sentCodeIds: Set<UInt32> = fixture.constructorIds(ofType: "auth.SentCode")
        guard let replyId: UInt32 = DevStackFixture.leadingConstructorId(of: reply) else {
            XCTFail("auth.sendCode returned no constructor")
            return
        }
        XCTAssertTrue(sentCodeIds.contains(replyId), "auth.sendCode did not return auth.SentCode")
    }


    func testLangPackForMacosReturnsDifference() async throws {
        try XCTSkipUnless(DevStackSettings.isEnabled, devStackSkipMessage)
        let fixture: DevStackFixture = try await DevStackFixture.make(settings: DevStackSettings.fromEnvironment())
        defer {
            fixture.close()
        }

        var writer: ImpulseTlWriter = try fixture.methodWriter("langpack.getLangPack")
        try writer.writeString(value: DevStackSettings.langPack)
        try writer.writeString(value: DevStackSettings.langCode)

        let reply: [UInt8] = try await fixture.call(method: "langpack.getLangPack", tl: writer.toByteArray())
        let differenceId: UInt32 = try fixture.constructorId(ofType: "LangPackDifference")
        XCTAssertEqual(DevStackFixture.leadingConstructorId(of: reply), differenceId)
    }
}
