import XCTest
@testable import ImpulseTransport


private final class MediaRequestTransportDouble: ImpulseMediaTransport {
    private let lock: NSLock = NSLock()
    private let immediate: Result<Data, ImpulseCarrierFailure>?
    private var sentMethods: [String] = []
    private var sentTimeouts: [TimeInterval] = []
    private var cancelCalls: Int = 0


    init(immediate: Result<Data, ImpulseCarrierFailure>?) {
        self.immediate = immediate
    }


    func send(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseCarrierFailure>) -> Void
    ) -> () -> Void {
        self.recordSend(method: method, timeout: timeoutSeconds)
        if let result: Result<Data, ImpulseCarrierFailure> = self.immediate {
            completion(result)
        }
        return { [weak self] () -> Void in
            self?.recordCancel()
            completion(.failure(ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:])))
        }
    }


    func close() {
    }


    func methods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentMethods
    }


    func timeouts() -> [TimeInterval] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentTimeouts
    }


    func cancels() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.cancelCalls
    }


    private func recordSend(
        method: String,
        timeout: TimeInterval
    ) {
        self.lock.lock()
        self.sentMethods.append(method)
        self.sentTimeouts.append(timeout)
        self.lock.unlock()
    }


    private func recordCancel() {
        self.lock.lock()
        self.cancelCalls += 1
        self.lock.unlock()
    }
}


final class ImpulseMediaRequestCarrierTests: XCTestCase {
    private func makeFleet(transport: MediaRequestTransportDouble) -> ImpulseMediaFleet {
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return transport
        })
        fleet.setConfig(
            dcOptions: [
                ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 8443, ipv6: false, mediaOnly: true),
            ],
            thisDc: 1
        )
        return fleet
    }


    func testMediaCallReachesTheEndpointWithTheMediaDeadline() async {
        let transport: MediaRequestTransportDouble = MediaRequestTransportDouble(
            immediate: .success(Data([5]))
        )
        let carrier: ImpulseMediaRequestCarrier = ImpulseMediaRequestCarrier(fleet: self.makeFleet(transport: transport))

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "upload.getFile",
            data: [1],
            timeoutSeconds: 0
        )

        XCTAssertEqual(result, .success([5]))
        XCTAssertEqual(transport.methods(), ["upload.getFile"])
        XCTAssertEqual(transport.timeouts(), [ImpulseMediaFleet.callTimeoutSeconds])
    }


    func testCarrierFailureKeepsItsCodes() async {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 0,
            appType: "",
            metadata: [:]
        )
        let transport: MediaRequestTransportDouble = MediaRequestTransportDouble(immediate: .failure(failure))
        let carrier: ImpulseMediaRequestCarrier = ImpulseMediaRequestCarrier(fleet: self.makeFleet(transport: transport))

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "upload.saveFilePart",
            data: [1],
            timeoutSeconds: 10
        )

        XCTAssertEqual(result, .failure(failure))
    }


    func testClosedFleetIsANetworkFailure() async {
        let transport: MediaRequestTransportDouble = MediaRequestTransportDouble(immediate: .success(Data()))
        let fleet: ImpulseMediaFleet = self.makeFleet(transport: transport)
        fleet.close()
        let carrier: ImpulseMediaRequestCarrier = ImpulseMediaRequestCarrier(fleet: fleet)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "upload.getFile",
            data: [1],
            timeoutSeconds: 10
        )

        XCTAssertEqual(result, .failure(ImpulseSdkFailure.networkFailure))
        XCTAssertEqual(transport.methods(), [])
    }


    func testCancellingTheTaskCancelsTheMediaCallOnce() async {
        let transport: MediaRequestTransportDouble = MediaRequestTransportDouble(immediate: nil)
        let carrier: ImpulseMediaRequestCarrier = ImpulseMediaRequestCarrier(fleet: self.makeFleet(transport: transport))
        let task: Task<Result<[UInt8], ImpulseCarrierFailure>, Never> = Task {
            return await carrier.send(method: "upload.getFile", data: [1], timeoutSeconds: 10)
        }

        task.cancel()
        let result: Result<[UInt8], ImpulseCarrierFailure> = await task.value

        XCTAssertEqual(transport.cancels(), 1)
        let cancelled: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:])
        XCTAssertEqual(result, .failure(cancelled))
    }


    func testFleetRefusalsAreNetworkFailures() {
        XCTAssertEqual(
            ImpulseMediaRequestCarrier.carrierFailure(from: .noConfig(method: "upload.getFile")),
            ImpulseSdkFailure.networkFailure
        )
        XCTAssertEqual(
            ImpulseMediaRequestCarrier.carrierFailure(from: .queueFull),
            ImpulseSdkFailure.networkFailure
        )
        XCTAssertEqual(
            ImpulseMediaRequestCarrier.carrierFailure(from: .requestTooLarge(bytes: 600_000)),
            ImpulseSdkFailure.networkFailure
        )
    }
}
