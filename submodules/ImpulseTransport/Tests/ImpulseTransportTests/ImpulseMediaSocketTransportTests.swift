import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class FakeMediaClient: ImpulseMediaClient {
    var connectCount: Int = 0
    var disconnectCount: Int = 0
    var cancelCount: Int = 0
    var sentMethods: [String] = []
    var sentPayloads: [Data] = []
    var sentTimeouts: [TimeInterval?] = []
    var sentHeaders: [[String: String]] = []
    var completions: [(Result<CentrifugeRpcResult, Error>) -> Void] = []


    func connect() {
        self.connectCount += 1
    }


    func sendRpc(
        method: String,
        data: Data,
        options: CentrifugeRpcOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) -> () -> Void {
        self.sentMethods.append(method)
        self.sentPayloads.append(data)
        self.sentTimeouts.append(options.timeout)
        self.sentHeaders.append(options.headers)
        self.completions.append(completion)
        return { [weak self] () -> Void in
            self?.cancelCount += 1
        }
    }


    func disconnect() {
        self.disconnectCount += 1
    }
}


private final class ResultRecorder {
    var results: [Result<Data, ImpulseCarrierFailure>] = []
}


final class ImpulseMediaSocketTransportTests: XCTestCase {
    func testSendForwardsMethodPayloadAndHeaders() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)
        let payload: Data = Data([1, 2, 3])

        _ = transport.send(
            method: "upload.saveFilePart",
            data: payload,
            timeoutSeconds: 4.0
        ) { (_: Result<Data, ImpulseCarrierFailure>) -> Void in
        }

        XCTAssertEqual(client.sentMethods, ["upload.saveFilePart"])
        XCTAssertEqual(client.sentPayloads, [payload])
        XCTAssertEqual(client.sentHeaders, [[:]])
        XCTAssertEqual(client.sentTimeouts.count, 1)
        XCTAssertEqual(client.sentTimeouts[0], 4.0)
    }


    func testDeadlineAboveMediaCallTimeoutIsCut() {
        XCTAssertEqual(ImpulseMediaSocketTransport.deadline(seconds: 30.0), ImpulseMediaFleet.callTimeoutSeconds)
    }


    func testDeadlineOfZeroOrLessUsesClientTimeout() {
        XCTAssertNil(ImpulseMediaSocketTransport.deadline(seconds: 0))
        XCTAssertNil(ImpulseMediaSocketTransport.deadline(seconds: -1.0))
    }


    func testDeadlineBelowCapIsKept() {
        XCTAssertEqual(ImpulseMediaSocketTransport.deadline(seconds: 2.5), 2.5)
    }


    func testSendCutsDeadlineToMediaCallTimeout() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)

        _ = transport.send(
            method: "upload.getFile",
            data: Data(),
            timeoutSeconds: 30.0
        ) { (_: Result<Data, ImpulseCarrierFailure>) -> Void in
        }

        XCTAssertEqual(client.sentTimeouts[0], ImpulseMediaFleet.callTimeoutSeconds)
    }


    func testReplyDataIsDelivered() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)
        let recorder: ResultRecorder = ResultRecorder()

        _ = transport.send(
            method: "upload.getFile",
            data: Data(),
            timeoutSeconds: 10.0
        ) { (result: Result<Data, ImpulseCarrierFailure>) -> Void in
            recorder.results.append(result)
        }
        client.completions[0](.success(CentrifugeRpcResult(data: Data([9, 8]))))

        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(try? recorder.results[0].get(), Data([9, 8]))
    }


    func testServerReplyErrorKeepsItsCodes() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)
        let recorder: ResultRecorder = ResultRecorder()
        let details: CentrifugeReplyError = CentrifugeReplyError(
            code: 3,
            message: "refused",
            temporary: false,
            appCode: 7,
            appType: "FILE_PART_INVALID",
            metadata: ["part": "2"]
        )

        _ = transport.send(
            method: "upload.saveFilePart",
            data: Data(),
            timeoutSeconds: 10.0
        ) { (result: Result<Data, ImpulseCarrierFailure>) -> Void in
            recorder.results.append(result)
        }
        client.completions[0](.failure(CentrifugeError.replyErrorDetails(details)))

        let expected: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 3,
            appCode: 7,
            appType: "FILE_PART_INVALID",
            metadata: ["part": "2"]
        )
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(failure(of: recorder.results[0]), expected)
    }


    func testNetworkErrorMapsToNetworkFailure() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)
        let recorder: ResultRecorder = ResultRecorder()

        _ = transport.send(
            method: "upload.getFile",
            data: Data(),
            timeoutSeconds: 10.0
        ) { (result: Result<Data, ImpulseCarrierFailure>) -> Void in
            recorder.results.append(result)
        }
        client.completions[0](.failure(CentrifugeError.timeout))

        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(failure(of: recorder.results[0]), ImpulseSdkFailure.networkFailure)
    }


    func testClientConnectsOnceOnFirstCall() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)

        _ = transport.send(method: "upload.getFile", data: Data(), timeoutSeconds: 1.0) { (_: Result<Data, ImpulseCarrierFailure>) -> Void in
        }
        _ = transport.send(method: "upload.getFile", data: Data(), timeoutSeconds: 1.0) { (_: Result<Data, ImpulseCarrierFailure>) -> Void in
        }

        XCTAssertEqual(client.connectCount, 1)
        XCTAssertEqual(client.sentMethods.count, 2)
    }


    func testCancelHandleCancelsTheRpcCall() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)

        let cancel: () -> Void = transport.send(method: "upload.getFile", data: Data(), timeoutSeconds: 1.0) { (_: Result<Data, ImpulseCarrierFailure>) -> Void in
        }
        cancel()

        XCTAssertEqual(client.cancelCount, 1)
    }


    func testCloseDisconnectsOnceAndRefusesLaterCalls() {
        let client: FakeMediaClient = FakeMediaClient()
        let transport: ImpulseMediaSocketTransport = ImpulseMediaSocketTransport(client: client)
        let recorder: ResultRecorder = ResultRecorder()

        transport.close()
        transport.close()
        _ = transport.send(
            method: "upload.getFile",
            data: Data(),
            timeoutSeconds: 1.0
        ) { (result: Result<Data, ImpulseCarrierFailure>) -> Void in
            recorder.results.append(result)
        }

        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertEqual(client.connectCount, 0)
        XCTAssertEqual(client.sentMethods.count, 0)
        XCTAssertEqual(recorder.results.count, 1)
        XCTAssertEqual(failure(of: recorder.results[0]), ImpulseSdkFailure.networkFailure)
    }


    func testConfigCarriesBackoffPingAndTimeout() {
        let config: CentrifugeClientConfig = ImpulseMediaSocketTransport.makeConfig(tokenGetter: { (_: CentrifugeConnectionTokenEvent, completion: @escaping (Result<String, Error>) -> Void) -> Void in
            completion(.success("token"))
        })

        XCTAssertEqual(config.minReconnectDelay, 1.0)
        XCTAssertEqual(config.maxReconnectDelay, 30.0)
        XCTAssertEqual(config.maxServerPingDelay, ImpulseMediaSocketTransport.maxServerPingDelaySeconds)
        XCTAssertEqual(config.timeout, ImpulseMediaFleet.callTimeoutSeconds)
        XCTAssertEqual(config.name, ImpulsePoolCarrier.clientName)
        XCTAssertNotNil(config.tokenGetter)
    }


    private func failure(of result: Result<Data, ImpulseCarrierFailure>) -> ImpulseCarrierFailure? {
        switch result {
        case .success:
            return nil

        case .failure(let failure):
            return failure
        }
    }
}
