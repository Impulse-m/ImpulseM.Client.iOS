import XCTest
@testable import ImpulseTransport


private struct RecordedRefreshSend {
    let method: String
    let data: [UInt8]
    let timeoutSeconds: TimeInterval
}


/// A request carrier that answers each call with the next scripted reply, at once. With no reply left it answers a
/// network failure, so no call can wait.
private final class ScriptedRefreshCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var scripted: [Result<[UInt8], ImpulseCarrierFailure>]
    private var sent: [RecordedRefreshSend] = []


    init(replies: [Result<[UInt8], ImpulseCarrierFailure>]) {
        self.scripted = replies
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        self.sent.append(RecordedRefreshSend(method: method, data: data, timeoutSeconds: timeoutSeconds))
        let next: Result<[UInt8], ImpulseCarrierFailure>? = self.scripted.isEmpty ? nil : self.scripted.removeFirst()
        self.lock.unlock()
        return next ?? .failure(ImpulseSdkFailure.networkFailure)
    }


    func calls() -> [RecordedRefreshSend] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sent
    }
}


private final class MemoryRefreshStorage: ImpulseSessionStorage, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: ImpulseSessionTokens?


    init(stored: ImpulseSessionTokens?) {
        self.stored = stored
    }


    func load() -> ImpulseSessionTokens? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.stored
    }


    func save(_ tokens: ImpulseSessionTokens) {
        self.lock.lock()
        self.stored = tokens
        self.lock.unlock()
    }


    func clear() {
        self.lock.lock()
        self.stored = nil
        self.lock.unlock()
    }
}


final class ImpulseRefreshTransportTests: XCTestCase {
    private func makeReply(
        userId: Int64?,
        sessionToken: String?,
        refreshToken: String?,
        grace: Int32?
    ) -> [UInt8] {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        if let userId: Int64 = userId {
            writer.writeInt64Field(field: 1, value: userId)
        }
        if let sessionToken: String = sessionToken {
            writer.writeBytesField(field: 2, value: Array(sessionToken.utf8))
        }
        if let refreshToken: String = refreshToken {
            writer.writeBytesField(field: 3, value: Array(refreshToken.utf8))
        }
        if let grace: Int32 = grace {
            writer.writeInt32Field(field: 4, value: grace)
        }
        return writer.toByteArray()
    }


    private func fullReply() -> [UInt8] {
        return self.makeReply(
            userId: 42,
            sessionToken: "access-new",
            refreshToken: "refresh-new",
            grace: 30
        )
    }


    func testRequestEncodesRefreshTokenAsFieldOne() async throws {
        let socket: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [])
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(self.fullReply())])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: socket,
            poolFleet: pool
        )

        _ = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .poolFleet,
            timeoutSeconds: 30
        )

        let calls: [RecordedRefreshSend] = pool.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.method, "refreshSession")
        XCTAssertEqual(calls.first?.data, [0x0A, 0x03, 0x61, 0x62, 0x63])
        XCTAssertEqual(calls.first?.timeoutSeconds, 30)
        XCTAssertEqual(socket.calls().count, 0)
    }


    func testUpdateSocketCarrierCarriesTheSocketRefresh() async throws {
        let socket: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(self.fullReply())])
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: socket,
            poolFleet: pool
        )

        let reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .updateSocket,
            timeoutSeconds: 12
        )

        XCTAssertEqual(socket.calls().count, 1)
        XCTAssertEqual(socket.calls().first?.timeoutSeconds, 12)
        XCTAssertEqual(pool.calls().count, 0)
        XCTAssertEqual(
            reply,
            .authorization(
                ImpulseRefreshAuthorization(
                    userId: 42,
                    sessionToken: "access-new",
                    refreshToken: "refresh-new",
                    grace: 30
                )
            )
        )
    }


    func testReplyMapsToAuthorization() async throws {
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(self.fullReply())])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        let reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .poolFleet,
            timeoutSeconds: 30
        )

        XCTAssertEqual(
            reply,
            .authorization(
                ImpulseRefreshAuthorization(
                    userId: 42,
                    sessionToken: "access-new",
                    refreshToken: "refresh-new",
                    grace: 30
                )
            )
        )
    }


    func testAbsentFieldsReadAsEmptyForTheTokenCheck() async throws {
        let reply: [UInt8] = self.makeReply(userId: nil, sessionToken: nil, refreshToken: nil, grace: nil)
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(reply)])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        let outcome: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .poolFleet,
            timeoutSeconds: 30
        )

        XCTAssertEqual(
            outcome,
            .authorization(
                ImpulseRefreshAuthorization(
                    userId: 0,
                    sessionToken: "",
                    refreshToken: "",
                    grace: 0
                )
            )
        )
    }


    func testUnknownFieldsAreSkipped() async throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeVarintField(field: 9, value: 7)
        writer.writeBytesField(field: 8, value: Array("ignored".utf8))
        writer.writeInt64Field(field: 1, value: 42)
        writer.writeBytesField(field: 2, value: Array("access-new".utf8))
        writer.writeBytesField(field: 3, value: Array("refresh-new".utf8))
        writer.writeInt32Field(field: 4, value: 30)
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(writer.toByteArray())])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        let reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .poolFleet,
            timeoutSeconds: 30
        )

        XCTAssertEqual(
            reply,
            .authorization(
                ImpulseRefreshAuthorization(
                    userId: 42,
                    sessionToken: "access-new",
                    refreshToken: "refresh-new",
                    grace: 30
                )
            )
        )
    }


    func testRefusedTokenIsReturnedAsFailure() async throws {
        let refusal: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 0,
            appType: "",
            metadata: [:]
        )
        let socket: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.failure(refusal)])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: socket,
            poolFleet: ScriptedRefreshCarrier(replies: [])
        )

        let reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .updateSocket,
            timeoutSeconds: 30
        )

        XCTAssertEqual(reply, .failure(refusal))
    }


    func testServerRpcErrorIsReturnedAsFailure() async throws {
        let rpcError: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 420,
            appType: "FLOOD_WAIT_5",
            metadata: [:]
        )
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.failure(rpcError)])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        let reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: "abc",
            carrier: .poolFleet,
            timeoutSeconds: 30
        )

        XCTAssertEqual(reply, .failure(rpcError))
    }


    func testNetworkFailureIsThrown() async {
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(
            replies: [.failure(ImpulseSdkFailure.networkFailure)]
        )
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        do {
            _ = try await transport.refreshSession(
                refreshToken: "abc",
                carrier: .poolFleet,
                timeoutSeconds: 30
            )
            XCTFail("a network failure must be thrown")
        } catch let error as ImpulseTokenError {
            XCTAssertEqual(error, .carrierFailure(ImpulseSdkFailure.networkFailure))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }


    func testCancelledCallIsThrown() async {
        let cancelled: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 17,
            appCode: 0,
            appType: "",
            metadata: [:]
        )
        let socket: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.failure(cancelled)])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: socket,
            poolFleet: ScriptedRefreshCarrier(replies: [])
        )

        do {
            _ = try await transport.refreshSession(
                refreshToken: "abc",
                carrier: .updateSocket,
                timeoutSeconds: 30
            )
            XCTFail("a cancelled call must be thrown")
        } catch let error as ImpulseTokenError {
            XCTAssertEqual(error, .carrierFailure(cancelled))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }


    func testTruncatedReplyIsThrown() async {
        let truncated: [UInt8] = [0x0A, 0x05, 0x61]
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(truncated)])
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: ScriptedRefreshCarrier(replies: []),
            poolFleet: pool
        )

        do {
            _ = try await transport.refreshSession(
                refreshToken: "abc",
                carrier: .poolFleet,
                timeoutSeconds: 30
            )
            XCTFail("an unreadable reply must be thrown")
        } catch let error as ImpulseRefreshTransportError {
            XCTAssertEqual(error, .undecodableReply)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }


    func testSocketRefusalFallsBackToThePoolAndRefreshes() async throws {
        let refusal: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 0,
            appType: "",
            metadata: [:]
        )
        let socket: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.failure(refusal)])
        let pool: ScriptedRefreshCarrier = ScriptedRefreshCarrier(replies: [.success(self.fullReply())])
        let storage: MemoryRefreshStorage = MemoryRefreshStorage(
            stored: ImpulseSessionTokens(
                accessToken: "access-old",
                refreshToken: "refresh-old",
                userId: 7
            )
        )
        let transport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: socket,
            poolFleet: pool
        )
        let tokens: ImpulseTokens = ImpulseTokens(storage: storage, transport: transport)

        let outcome: ImpulseRefreshOutcome = try await tokens.refresh()

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(socket.calls().count, 1)
        XCTAssertEqual(pool.calls().count, 1)
        let expectedRequest: [UInt8] = [0x0A, 0x0B] + Array("refresh-old".utf8)
        XCTAssertEqual(pool.calls().first?.data, expectedRequest)
        XCTAssertEqual(
            storage.load(),
            ImpulseSessionTokens(
                accessToken: "access-new",
                refreshToken: "refresh-new",
                userId: 42
            )
        )
    }
}
