import Foundation
import XCTest
@testable import ImpulseTransport


private actor TelemetrySinkTestRequester: ImpulseTelemetryRequester {
    private(set) var requests: [ImpulseEncodedRequest] = []
    private(set) var options: [ImpulseRequestOptions] = []
    private let result: Result<[UInt8], ImpulseRequestFailure>


    init(result: Result<[UInt8], ImpulseRequestFailure>) {
        self.result = result
    }


    func execute(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions
    ) async -> Result<[UInt8], ImpulseRequestFailure> {
        self.requests.append(request)
        self.options.append(options)
        return self.result
    }
}


private struct TelemetrySinkTestSession: ImpulseRequestSession {
    func hasSession() async -> Bool {
        return false
    }


    func needsProactiveRefresh() async -> Bool {
        return false
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        return .refreshed
    }
}


private actor TelemetrySinkTestCarrier: ImpulseRequestCarrier {
    private(set) var methods: [String] = []


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        self.methods.append(method)
        return .success([])
    }
}


final class ImpulseRequestTelemetrySinkTests: XCTestCase {
    private let saveAppLogMethodId: UInt32 = 0x6f02f748
    private let getConfigBytes: [UInt8] = [0x6b, 0x18, 0xf9, 0xc4]
    private let unmappedBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00]


    private func makeTranscoder() throws -> ImpulseTranscoder {
        return ImpulseTranscoder(mapping: try ImpulseMapping.loadBundled())
    }


    private func saveAppLogBytes() throws -> [UInt8] {
        let event: ImpulseTelemetryEvent = ImpulseTelemetryEvent(
            name: .networkSummary,
            time: 1.5,
            fields: [ImpulseTelemetryEncoding.appNameField: .string(ImpulseTelemetryEncoding.appName)]
        )
        return try ImpulseTelemetryEncoding.saveAppLogRequest(events: [event])
    }


    func testBatchIsSentAsSaveAppLogWithTheSinkOptions() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .success([]))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )

        try await sink.saveAppLog(request: try saveAppLogBytes())

        let requests: [ImpulseEncodedRequest] = await requester.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "help.saveAppLog")
        XCTAssertEqual(requests[0].methodId, saveAppLogMethodId)
        XCTAssertFalse(requests[0].proto.isEmpty)

        let options: [ImpulseRequestOptions] = await requester.options
        XCTAssertEqual(options, [ImpulseRequestTelemetrySink.requestOptions])
    }


    func testSinkOptionsNeedNoLoginAndNeverRetryServerErrors() {
        let options: ImpulseRequestOptions = ImpulseRequestTelemetrySink.requestOptions
        XCTAssertTrue(options.withoutLogin)
        XCTAssertTrue(options.failOnServerErrors)
        XCTAssertTrue(options.doNotWaitFloodWait)
        XCTAssertEqual(options.totalDeadlineSeconds, ImpulseRequestTimeouts.updateCallSeconds)
    }


    func testRequestFailureIsThrown() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .failure(.canceled))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )

        do {
            try await sink.saveAppLog(request: try saveAppLogBytes())
            XCTFail("A failed request must be thrown")
        } catch let error as ImpulseTelemetrySinkError {
            XCTAssertEqual(error, .requestFailed(.canceled))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }


    func testRequestThatIsNotSaveAppLogIsRefused() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .success([]))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )

        do {
            try await sink.saveAppLog(request: getConfigBytes)
            XCTFail("Only help.saveAppLog may be sent by the telemetry sink")
        } catch let error as ImpulseTelemetrySinkError {
            XCTAssertEqual(error, .unexpectedMethod("help.getConfig"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let requests: [ImpulseEncodedRequest] = await requester.requests
        XCTAssertTrue(requests.isEmpty)
    }


    func testUnmappedRequestIsNotSent() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .success([]))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )

        do {
            try await sink.saveAppLog(request: unmappedBytes)
            XCTFail("An unmapped request must not be sent")
        } catch let error as ImpulseTelemetrySinkError {
            guard case .encodeFailed = error else {
                XCTFail("Expected an encode failure, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let requests: [ImpulseEncodedRequest] = await requester.requests
        XCTAssertTrue(requests.isEmpty)
    }


    func testTelemetryQueueSendsOneBatchThroughTheSink() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .success([]))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["requests": .number(3)])
        try await telemetry.record(name: ImpulseTelemetryEventName.networkFailures.rawValue, fields: ["offset": .number(0)])
        await telemetry.flush()

        let requests: [ImpulseEncodedRequest] = await requester.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "help.saveAppLog")

        let pendingCount: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }


    func testFailedBatchIsDroppedWithoutRetry() async throws {
        let requester: TelemetrySinkTestRequester = TelemetrySinkTestRequester(result: .failure(.canceled))
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: requester
        )
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: [:])
        await telemetry.flush()
        await telemetry.flush()

        let requests: [ImpulseEncodedRequest] = await requester.requests
        XCTAssertEqual(requests.count, 1)

        let pendingCount: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }


    func testSaveAppLogRoutesToTheUpdateCarrierThroughTheRequestService() async throws {
        let carrier: TelemetrySinkTestCarrier = TelemetrySinkTestCarrier()
        let service: ImpulseRequestService = ImpulseRequestService(
            session: TelemetrySinkTestSession(),
            updateCarrier: carrier,
            mediaCarrier: carrier,
            poolCarrier: carrier,
            declarations: nil,
            signedIn: false,
            onAuthorizationRequired: {}
        )
        let sink: ImpulseRequestTelemetrySink = ImpulseRequestTelemetrySink(
            transcoder: try makeTranscoder(),
            requester: service
        )

        try await sink.saveAppLog(request: try saveAppLogBytes())

        let methods: [String] = await carrier.methods
        XCTAssertEqual(methods, ["help.saveAppLog"])
    }
}
