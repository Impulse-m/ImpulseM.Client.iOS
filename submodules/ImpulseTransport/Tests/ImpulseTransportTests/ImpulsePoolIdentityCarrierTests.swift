import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class PoolIdentityRequestCarrierDouble: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let result: Result<[UInt8], ImpulseCarrierFailure>
    private var sentMethods: [String] = []
    private var sentRequests: [[UInt8]] = []
    private var sentTimeouts: [TimeInterval] = []


    init(result: Result<[UInt8], ImpulseCarrierFailure>) {
        self.result = result
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.lock.lock()
        self.sentMethods.append(method)
        self.sentRequests.append(data)
        self.sentTimeouts.append(timeoutSeconds)
        self.lock.unlock()
        return self.result
    }


    func methods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentMethods
    }


    func requests() -> [[UInt8]] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentRequests
    }


    func timeouts() -> [TimeInterval] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentTimeouts
    }
}


private final class PoolIdentityMainDouble: ImpulsePoolMain {
    var state: CentrifugeClientState = .connected


    func connect() {
    }


    func disconnect() {
    }
}


private final class PoolIdentityTransportDouble: ImpulsePoolTransport {
    private let immediate: Result<Data, Error>
    private let lock: NSLock = NSLock()
    private var sentMethods: [String] = []
    private var sentData: [Data] = []


    init(immediate: Result<Data, Error>) {
        self.immediate = immediate
    }


    func send(
        endpointKey: String,
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        self.lock.lock()
        self.sentMethods.append(method)
        self.sentData.append(data)
        self.lock.unlock()
        completion(self.immediate)
        return {
        }
    }


    func methods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentMethods
    }


    func payloads() -> [Data] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentData
    }
}


private func identityReplyBytes(token: String) -> [UInt8] {
    var writer: ImpulseProtoWriter = ImpulseProtoWriter()
    writer.writeBytesField(field: 1, value: Array(token.utf8))
    return writer.toByteArray()
}


private func makePoolIdentityPool(transport: PoolIdentityTransportDouble) -> ImpulsePoolCarrier {
    let pool: ImpulsePoolCarrier = ImpulsePoolCarrier(
        main: PoolIdentityMainDouble(),
        transport: transport,
        identityRenewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
            completion(.success(()))
        },
        clock: { () -> UInt64 in
            return 0
        },
        tickInterval: nil
    )
    return pool
}


final class ImpulsePoolIdentityCarrierTests: XCTestCase {
    func testMintRequestCarriesOnlyTheApiId() async throws {
        let double: PoolIdentityRequestCarrierDouble = PoolIdentityRequestCarrierDouble(
            result: .success(identityReplyBytes(token: "a.b.c"))
        )
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: double)

        let token: String = try await carrier.connectionIdentity(
            identityToken: "",
            apiId: 4,
            timeoutSeconds: 30
        )

        XCTAssertEqual(token, "a.b.c")
        XCTAssertEqual(double.methods(), ["connectionIdentity"])
        XCTAssertEqual(double.requests(), [[0x10, 0x04]])
        XCTAssertEqual(double.timeouts(), [30])
    }


    func testRenewalRequestCarriesTheTokenThenTheApiId() async throws {
        let double: PoolIdentityRequestCarrierDouble = PoolIdentityRequestCarrierDouble(
            result: .success(identityReplyBytes(token: "renewed"))
        )
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: double)

        let token: String = try await carrier.connectionIdentity(
            identityToken: "abc",
            apiId: 4,
            timeoutSeconds: 30
        )

        XCTAssertEqual(token, "renewed")
        XCTAssertEqual(double.requests(), [[0x0A, 0x03, 0x61, 0x62, 0x63, 0x10, 0x04]])
    }


    func testZeroApiIdAndEmptyTokenWriteNothing() async throws {
        let double: PoolIdentityRequestCarrierDouble = PoolIdentityRequestCarrierDouble(
            result: .success([])
        )
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: double)

        _ = try await carrier.connectionIdentity(
            identityToken: "",
            apiId: 0,
            timeoutSeconds: 30
        )

        XCTAssertEqual(double.requests(), [[]])
    }


    func testNegativeApiIdUsesTheTenByteVarint() async throws {
        let double: PoolIdentityRequestCarrierDouble = PoolIdentityRequestCarrierDouble(
            result: .success([])
        )
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: double)

        _ = try await carrier.connectionIdentity(
            identityToken: "",
            apiId: -1,
            timeoutSeconds: 30
        )

        let expected: [UInt8] = [0x10, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        XCTAssertEqual(double.requests(), [expected])
    }


    func testReplyTokenIsReturned() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([0x0A, 0x03, 0x61, 0x62, 0x63])

        XCTAssertEqual(token, "abc")
    }


    func testEmptyReplyIsANullIdentity() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([])

        XCTAssertEqual(token, "")
    }


    func testReplyWithEmptyTokenIsANullIdentity() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([0x0A, 0x00])

        XCTAssertEqual(token, "")
    }


    func testReplyWithoutTokenFieldIsANullIdentity() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([0x10, 0x05])

        XCTAssertEqual(token, "")
    }


    func testReplyTokenFieldOfAnotherWireTypeIsSkipped() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([0x08, 0x05])

        XCTAssertEqual(token, "")
    }


    func testUnknownFieldsAreSkippedBeforeTheToken() throws {
        let token: String = try ImpulsePoolIdentityCarrier.decodeReply([0x10, 0x05, 0x0A, 0x01, 0x78])

        XCTAssertEqual(token, "x")
    }


    func testTruncatedReplyThrows() {
        XCTAssertThrowsError(try ImpulsePoolIdentityCarrier.decodeReply([0x0A, 0x05, 0x61]))
    }


    func testCarrierFailureIsThrownUnchanged() async {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 400,
            appType: "API_ID_INVALID",
            metadata: [:]
        )
        let double: PoolIdentityRequestCarrierDouble = PoolIdentityRequestCarrierDouble(
            result: .failure(failure)
        )
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: double)

        do {
            _ = try await carrier.connectionIdentity(
                identityToken: "",
                apiId: 4,
                timeoutSeconds: 30
            )
            XCTFail("A failed call must throw.")
        } catch let thrown as ImpulseCarrierFailure {
            XCTAssertEqual(thrown, failure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }


    func testMintThroughThePoolReturnsTheReplyToken() async throws {
        let transport: PoolIdentityTransportDouble = PoolIdentityTransportDouble(
            immediate: .success(Data(identityReplyBytes(token: "pool.token.sig")))
        )
        let pool: ImpulsePoolCarrier = makePoolIdentityPool(transport: transport)
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(
            carrier: ImpulsePoolRequestCarrier(pool: pool)
        )

        let token: String = try await carrier.connectionIdentity(
            identityToken: "",
            apiId: 4,
            timeoutSeconds: 30
        )

        XCTAssertEqual(token, "pool.token.sig")
        XCTAssertEqual(transport.methods(), ["connectionIdentity"])
        XCTAssertEqual(transport.payloads(), [Data([0x10, 0x04])])
    }


    func testClientDisconnectedFromTheTransportIsANetworkFailure() async {
        let transport: PoolIdentityTransportDouble = PoolIdentityTransportDouble(
            immediate: .failure(CentrifugeError.clientDisconnected)
        )
        let pool: ImpulsePoolCarrier = makePoolIdentityPool(transport: transport)
        let carrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(
            carrier: ImpulsePoolRequestCarrier(pool: pool)
        )

        do {
            _ = try await carrier.connectionIdentity(
                identityToken: "",
                apiId: 4,
                timeoutSeconds: 30
            )
            XCTFail("A disconnected pool must fail the call.")
        } catch let thrown as ImpulseCarrierFailure {
            XCTAssertEqual(thrown, ImpulseSdkFailure.networkFailure)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
