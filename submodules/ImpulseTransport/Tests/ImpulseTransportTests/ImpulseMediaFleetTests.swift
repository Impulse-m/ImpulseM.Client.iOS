import XCTest
@testable import ImpulseTransport


private final class FakeMediaTransport: ImpulseMediaTransport {
    var sent: [String] = []
    var lastTimeout: TimeInterval? = nil
    var completions: [(Result<Data, ImpulseCarrierFailure>) -> Void] = []
    var closeCount: Int = 0


    func send(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseCarrierFailure>) -> Void
    ) -> () -> Void {
        self.sent.append(method)
        self.lastTimeout = timeoutSeconds
        self.completions.append(completion)
        return {}
    }


    func close() {
        self.closeCount += 1
    }
}


private final class MediaTransportRecorder {
    var endpoints: [String] = []
    var transports: [FakeMediaTransport] = []


    func make(endpoint: String) -> ImpulseMediaTransport {
        self.endpoints.append(endpoint)
        let transport: FakeMediaTransport = FakeMediaTransport()
        self.transports.append(transport)
        return transport
    }
}


private final class MediaResultRecorder {
    var results: [Result<Data, ImpulseMediaFailure>] = []


    func failure(at index: Int) -> ImpulseMediaFailure? {
        guard index < self.results.count else {
            return nil
        }
        switch self.results[index] {
        case .success:
            return nil
        case .failure(let failure):
            return failure
        }
    }
}


final class ImpulseMediaFleetTests: XCTestCase {
    private static let mediaSuffix: String = "/connection/websocket?cf_protocol=protobuf&cf_ws_frame_ping_pong=true"


    func testLimitsMatchTheMediaFleet() {
        XCTAssertEqual(ImpulseMediaFleet.connectionsPerEndpoint, 2)
        XCTAssertEqual(ImpulseMediaFleet.inflightPerConnection, 2)
        XCTAssertEqual(ImpulseMediaFleet.maxQueued, 64)
        XCTAssertEqual(ImpulseMediaFleet.callTimeoutSeconds, 10.0)
        XCTAssertEqual(ImpulseMediaFleet.requestByteCap, 557_056)
        XCTAssertEqual(ImpulseMediaFleet.partBytes, 512 * 1024)
    }


    func testEndpointComesFromTheMediaOptionOfThisDc() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.setConfig(
            dcOptions: [
                ImpulseDcOption(id: 2, ipAddress: "198.51.100.2", port: 443, ipv6: false, mediaOnly: true),
                ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 8443, ipv6: false, mediaOnly: true),
            ],
            thisDc: 1
        )
        fleet.drainQueue()
        XCTAssertEqual(recorder.endpoints, ["wss://203.0.113.5:8443" + ImpulseMediaFleetTests.mediaSuffix])
        XCTAssertEqual(recorder.transports.first?.sent, ["upload.getFile"])
    }


    func testCallsMadeBeforeConfigWaitForIt() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        _ = fleet.call(method: "upload.saveFilePart", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        XCTAssertTrue(recorder.transports.isEmpty)
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.sent, ["upload.saveFilePart"])
    }


    func testMissingMediaOptionFailsWithNoConfigText() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "198.51.100.1", port: 443, ipv6: false, mediaOnly: false)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.saveFilePart", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(results.failure(at: 0), .noConfig(method: "upload.saveFilePart"))
        XCTAssertEqual(results.failure(at: 0)?.text, "no config yet for upload.saveFilePart")
        XCTAssertTrue(recorder.transports.isEmpty)
    }


    func testQueuedCallExpiresWithNoConfig() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(
            makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
                return recorder.make(endpoint: endpoint)
            },
            deadlineSeconds: 0.05
        )
        let expectation: XCTestExpectation = XCTestExpectation(description: "queued call expires")
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(results.failure(at: 0), .noConfig(method: "upload.getFile"))
        XCTAssertTrue(recorder.transports.isEmpty)
    }


    func testQueueHoldsSixtyFourCallsBeforeConfig() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        for _ in 0..<ImpulseMediaFleet.maxQueued {
            _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
                results.results.append(result)
            }
        }
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.failure(at: 0), .queueFull)
    }


    func testRequestOverTheCapIsRefusedLocally() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        let results: MediaResultRecorder = MediaResultRecorder()
        let overCap: Data = Data(count: ImpulseMediaFleet.requestByteCap + 1)
        _ = fleet.call(method: "upload.saveBigFilePart", data: overCap, timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(results.failure(at: 0), .requestTooLarge(bytes: ImpulseMediaFleet.requestByteCap + 1))
        XCTAssertTrue(recorder.transports.first?.sent.isEmpty ?? true)
    }


    func testRequestAtTheCapIsSent() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        let atCap: Data = Data(count: ImpulseMediaFleet.requestByteCap)
        _ = fleet.call(method: "upload.saveBigFilePart", data: atCap, timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.sent, ["upload.saveBigFilePart"])
    }


    func testCallDeadlineIsCutToTenSeconds() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 30) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.lastTimeout, 10.0)
    }


    func testReplyAndCarrierFailureAreRelayed() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        let transport: FakeMediaTransport = recorder.transports[0]
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 400,
            appType: "FILE_PART_INVALID",
            metadata: [:]
        )
        transport.completions[0](.success(Data([7, 8])))
        transport.completions[1](.failure(failure))
        fleet.drainQueue()
        XCTAssertEqual(results.results.count, 2)
        if case .success(let reply) = results.results[0] {
            XCTAssertEqual(reply, Data([7, 8]))
        } else {
            XCTFail("expected a reply")
        }
        XCTAssertEqual(results.failure(at: 1), .carrier(failure))
    }


    func testCancelOfAWaitingCallSettlesWithCancel() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        let call: ImpulseMediaCall = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        call.cancel()
        fleet.drainQueue()
        XCTAssertEqual(
            results.failure(at: 0),
            .carrier(ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:]))
        )
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        fleet.drainQueue()
        XCTAssertTrue(recorder.transports.isEmpty)
    }


    func testCloseClosesTheCarrierAndRefusesNewCalls() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.close()
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.closeCount, 1)
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(results.failure(at: 0), .closed)
    }


    func testCloseFailsWaitingCalls() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.close()
        fleet.drainQueue()
        XCTAssertEqual(results.failure(at: 0), .closed)
        XCTAssertTrue(recorder.transports.isEmpty)
    }


    func testEndpointChangeRetiresTheOldCarrier() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        fleet.drainQueue()
        XCTAssertEqual(recorder.endpoints.count, 1)
        XCTAssertEqual(recorder.transports.first?.closeCount, 0)
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.9", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.closeCount, 1)
        XCTAssertEqual(recorder.endpoints.count, 2)
        XCTAssertEqual(recorder.endpoints.last, "wss://203.0.113.9:443" + ImpulseMediaFleetTests.mediaSuffix)
    }


    func testResetFailsWaitingCallsWithRouteChangedOnce() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(
            makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
                return recorder.make(endpoint: endpoint)
            },
            deadlineSeconds: 60.0
        )
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        fleet.reset()
        fleet.drainQueue()
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.failure(at: 0), .routeChanged)
        XCTAssertEqual(results.failure(at: 0)?.text, "media route changed")
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        fleet.drainQueue()
        XCTAssertEqual(results.results.count, 1)
        XCTAssertTrue(recorder.transports.isEmpty)
    }


    func testCallAfterResetUsesANewCarrier() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        fleet.reset()
        fleet.drainQueue()
        XCTAssertEqual(recorder.transports.first?.closeCount, 1)
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.saveFilePart", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(recorder.endpoints, [
            "wss://203.0.113.5:443" + ImpulseMediaFleetTests.mediaSuffix,
            "wss://203.0.113.5:443" + ImpulseMediaFleetTests.mediaSuffix,
        ])
        XCTAssertEqual(recorder.transports.count, 2)
        XCTAssertEqual(recorder.transports[1].sent, ["upload.saveFilePart"])
        XCTAssertTrue(results.results.isEmpty)
    }


    func testCloseStaysTerminalAfterReset() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        fleet.setConfig(
            dcOptions: [ImpulseDcOption(id: 1, ipAddress: "203.0.113.5", port: 443, ipv6: false, mediaOnly: true)],
            thisDc: 1
        )
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (_: Result<Data, ImpulseMediaFailure>) -> Void in
        }
        fleet.drainQueue()
        fleet.reset()
        fleet.close()
        fleet.reset()
        fleet.drainQueue()
        let results: MediaResultRecorder = MediaResultRecorder()
        _ = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        fleet.drainQueue()
        XCTAssertEqual(results.failure(at: 0), .closed)
        XCTAssertEqual(recorder.transports.count, 1)
    }


    func testCancelledWaitingCallIsNotSettledAgainByReset() {
        let recorder: MediaTransportRecorder = MediaTransportRecorder()
        let fleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return recorder.make(endpoint: endpoint)
        })
        let results: MediaResultRecorder = MediaResultRecorder()
        let call: ImpulseMediaCall = fleet.call(method: "upload.getFile", data: Data([1]), timeoutSeconds: 0) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
            results.results.append(result)
        }
        call.cancel()
        fleet.drainQueue()
        fleet.reset()
        fleet.drainQueue()
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(
            results.failure(at: 0),
            .carrier(ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:]))
        )
        XCTAssertTrue(recorder.transports.isEmpty)
    }
}
