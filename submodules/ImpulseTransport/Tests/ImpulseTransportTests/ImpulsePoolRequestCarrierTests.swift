import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class PoolRequestMainDouble: ImpulsePoolMain {
    var state: CentrifugeClientState = .connected


    func connect() {
    }
}


private final class PoolRequestTransportDouble: ImpulsePoolTransport {
    private let lock: NSLock = NSLock()
    private let immediate: Result<Data, Error>?
    private var sentMethods: [String] = []
    private var sentTimeouts: [TimeInterval?] = []


    init(immediate: Result<Data, Error>?) {
        self.immediate = immediate
    }


    func send(
        endpointKey: String,
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        self.recordSend(method: method, timeout: timeout)
        if let result: Result<Data, Error> = self.immediate {
            completion(result)
        }
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


    func timeouts() -> [TimeInterval?] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentTimeouts
    }


    private func recordSend(
        method: String,
        timeout: TimeInterval?
    ) {
        self.lock.lock()
        self.sentMethods.append(method)
        self.sentTimeouts.append(timeout)
        self.lock.unlock()
    }
}


final class ImpulsePoolRequestCarrierTests: XCTestCase {
    private func makeCarrier(transport: PoolRequestTransportDouble) -> ImpulsePoolRequestCarrier {
        let pool: ImpulsePoolCarrier = ImpulsePoolCarrier(
            main: PoolRequestMainDouble(),
            transport: transport,
            identityRenewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                completion(.success(()))
            },
            clock: { () -> UInt64 in
                return 0
            },
            tickInterval: nil
        )
        return ImpulsePoolRequestCarrier(pool: pool)
    }


    func testServedMethodReturnsTheReplyWithTheCappedDeadline() async {
        let transport: PoolRequestTransportDouble = PoolRequestTransportDouble(immediate: .success(Data([7])))
        let carrier: ImpulsePoolRequestCarrier = self.makeCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "connectionIdentity",
            data: [1],
            timeoutSeconds: 60
        )

        XCTAssertEqual(result, .success([7]))
        XCTAssertEqual(transport.methods(), ["connectionIdentity"])
        let expectedTimeouts: [TimeInterval?] = [ImpulsePoolCarrier.callTimeoutSeconds]
        XCTAssertEqual(transport.timeouts(), expectedTimeouts)
    }


    func testMethodOutsideThePoolIsRefusedWithoutBeingSent() async {
        let transport: PoolRequestTransportDouble = PoolRequestTransportDouble(immediate: .success(Data()))
        let carrier: ImpulsePoolRequestCarrier = self.makeCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "messages.sendMessage",
            data: [],
            timeoutSeconds: 30
        )

        let refusal: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 400,
            appType: "CLIENT_IDENTITY_REFUSED",
            metadata: [:]
        )
        XCTAssertEqual(result, .failure(refusal))
        XCTAssertEqual(transport.methods(), [])
    }


    func testDisconnectedMainIsANetworkFailure() async {
        let transport: PoolRequestTransportDouble = PoolRequestTransportDouble(
            immediate: .failure(CentrifugeError.clientDisconnected)
        )
        let carrier: ImpulsePoolRequestCarrier = self.makeCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "refreshSession",
            data: [],
            timeoutSeconds: 30
        )

        XCTAssertEqual(result, .failure(ImpulseSdkFailure.networkFailure))
    }


    func testEndedSessionIsANetworkFailure() async {
        let transport: PoolRequestTransportDouble = PoolRequestTransportDouble(
            immediate: .failure(CentrifugeError.unauthorized)
        )
        let carrier: ImpulsePoolRequestCarrier = self.makeCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "connectionIdentity",
            data: [],
            timeoutSeconds: 30
        )

        XCTAssertEqual(result, .failure(ImpulseSdkFailure.networkFailure))
    }


    func testServerReplyKeepsItsCodes() async {
        let details: CentrifugeReplyError = CentrifugeReplyError(
            code: 400,
            message: "bad request",
            temporary: false,
            appCode: 9,
            appType: "IDENTITY_REJECTED",
            metadata: [:]
        )
        let transport: PoolRequestTransportDouble = PoolRequestTransportDouble(
            immediate: .failure(CentrifugeError.replyErrorDetails(details))
        )
        let carrier: ImpulsePoolRequestCarrier = self.makeCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "connectionIdentity",
            data: [],
            timeoutSeconds: 30
        )

        let expected: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 400,
            appCode: 9,
            appType: "IDENTITY_REJECTED",
            metadata: [:]
        )
        XCTAssertEqual(result, .failure(expected))
    }
}
