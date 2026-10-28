import Foundation
import XCTest
@testable import ImpulseTransport


private enum FakeTelemetrySinkError: Error {
    case rejected
}


private actor FakeTelemetrySink: ImpulseTelemetrySink {
    private(set) var requests: [[UInt8]] = []
    private(set) var attempts: Int = 0
    private let shouldFail: Bool


    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }


    func saveAppLog(request: [UInt8]) async throws {
        attempts += 1

        if shouldFail {
            throw FakeTelemetrySinkError.rejected
        }

        requests.append(request)
    }
}


final class ImpulseTelemetryTests: XCTestCase {
    private let fixedTime: Double = 1.5
    private let saveAppLogPrefix: [UInt8] = [0x48, 0xf7, 0x02, 0x6f]
    private let vectorPrefix: [UInt8] = [0x15, 0xc4, 0xb5, 0x1c]
    private let inputAppEventPrefix: [UInt8] = [0x45, 0x12, 0x1b, 0x1d]


    func testAppNameIsCanonical() {
        XCTAssertEqual(ImpulseTelemetryEncoding.appName, "ImpulseM.Mac")
        XCTAssertEqual(ImpulseTelemetryEncoding.appNameField, "app_name")
    }


    func testKnownEventNamesAreTheCanonicalSinkTypes() {
        XCTAssertEqual(ImpulseTelemetryEventName.networkSummary.rawValue, "network_telemetry_summary")
        XCTAssertEqual(ImpulseTelemetryEventName.networkFailures.rawValue, "network_telemetry_failures")
        XCTAssertEqual(ImpulseTelemetryEventName.allCases.count, 2)
    }


    func testUnknownEventNameIsRefusedAndNothingIsQueued() async {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        do {
            try await telemetry.record(name: "unknown_event", fields: [:])
            XCTFail("An unknown event name must be refused")
        } catch let error as ImpulseTelemetryError {
            XCTAssertEqual(error, .unknownEventName("unknown_event"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        let pendingCount: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }


    func testEventsAreBatchedIntoOneSaveAppLogRequest() async throws {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["requests": .number(3)])
        try await telemetry.record(name: ImpulseTelemetryEventName.networkFailures.rawValue, fields: ["offset": .number(0)])
        try await telemetry.record(name: ImpulseTelemetryEventName.networkFailures.rawValue, fields: ["offset": .number(10)])

        let pendingBefore: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingBefore, 3)

        await telemetry.flush()

        let requests: [[UInt8]] = await sink.requests
        XCTAssertEqual(requests.count, 1)

        let request: [UInt8] = requests[0]
        XCTAssertEqual(Array(request[0 ..< 4]), saveAppLogPrefix)
        XCTAssertEqual(Array(request[4 ..< 8]), vectorPrefix)
        XCTAssertEqual(Array(request[8 ..< 12]), [0x03, 0x00, 0x00, 0x00])

        let pendingAfter: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingAfter, 0)
    }


    func testReachingBatchSizeSendsAndKeepsTheRest() async throws {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, maxBatchSize: 2, clock: { 1.5 })

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: [:])
        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: [:])

        let sentAfterTwo: Int = await sink.requests.count
        XCTAssertEqual(sentAfterTwo, 1)

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: [:])
        await telemetry.flush()

        let requests: [[UInt8]] = await sink.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Array(requests[0][8 ..< 12]), [0x02, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(requests[1][8 ..< 12]), [0x01, 0x00, 0x00, 0x00])
    }


    func testEachEventCarriesTheAppNameAndTime() throws {
        let event: ImpulseTelemetryEvent = ImpulseTelemetryEvent(
            name: .networkSummary,
            time: fixedTime,
            fields: [ImpulseTelemetryEncoding.appNameField: .string(ImpulseTelemetryEncoding.appName)]
        )
        let request: [UInt8] = try ImpulseTelemetryEncoding.saveAppLogRequest(events: [event])

        XCTAssertEqual(Array(request[12 ..< 16]), inputAppEventPrefix)
        XCTAssertEqual(Array(request[16 ..< 24]), [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f])
        XCTAssertTrue(containsSubsequence(request, Array("ImpulseM.Mac".utf8)))
        XCTAssertTrue(containsSubsequence(request, Array("app_name".utf8)))
    }


    func testSecretFieldNamesAreRefused() async {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })
        let secretNames: [String] = [
            "access_token",
            "refresh_token",
            "identity_token",
            "password",
            "auth_key",
            "session_hash",
            "client_secret",
        ]

        for name: String in secretNames {
            do {
                try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: [name: .number(1)])
                XCTFail("Secret-looking field \(name) must be refused")
            } catch let error as ImpulseTelemetryError {
                if case .secretField = error {
                    continue
                }

                XCTFail("Unexpected refusal \(error) for \(name)")
            } catch {
                XCTFail("Unexpected error \(error)")
            }
        }

        let pendingCount: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }


    func testSecretValuesAreRefusedAndNeverSent() async throws {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })
        let bearer: String = "Bearer tok-SECRET-VALUE-123"
        let jwt: String = "eyJhbGciOiJIUzI1NiJ9.SECRET"

        do {
            try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["detail": .string(bearer)])
            XCTFail("A bearer value must be refused")
        } catch let error as ImpulseTelemetryError {
            XCTAssertEqual(error, .secretField("detail"))
        }

        do {
            try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["detail": .string(jwt)])
            XCTFail("A JWT-shaped value must be refused")
        } catch let error as ImpulseTelemetryError {
            XCTAssertEqual(error, .secretField("detail"))
        }

        try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["requests": .number(4)])
        await telemetry.flush()

        let requests: [[UInt8]] = await sink.requests
        XCTAssertEqual(requests.count, 1)

        let secretBytes: [UInt8] = Array("SECRET".utf8)
        XCTAssertFalse(containsSubsequence(requests[0], secretBytes))
        XCTAssertFalse(containsSubsequence(requests[0], Array("tok-".utf8)))
    }


    func testInvalidFieldNameAndNonFiniteNumberAreRefused() async {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: false)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        do {
            try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["Bad-Key": .number(1)])
            XCTFail("An upper-case or dashed field name must be refused")
        } catch let error as ImpulseTelemetryError {
            XCTAssertEqual(error, .invalidFieldName("Bad-Key"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        do {
            try await telemetry.record(name: ImpulseTelemetryEventName.networkSummary.rawValue, fields: ["ratio": .number(Double.nan)])
            XCTFail("A NaN value must be refused")
        } catch let error as ImpulseTelemetryError {
            XCTAssertEqual(error, .invalidFieldValue("ratio"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }


    func testFailedSendIsDroppedWithoutRetryOrFallback() async throws {
        let sink: FakeTelemetrySink = FakeTelemetrySink(shouldFail: true)
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(sink: sink, clock: { 1.5 })

        try await telemetry.record(name: ImpulseTelemetryEventName.networkFailures.rawValue, fields: ["offset": .number(0)])
        await telemetry.flush()

        let pendingAfterFailure: Int = await telemetry.pendingCount
        XCTAssertEqual(pendingAfterFailure, 0)

        await telemetry.flush()

        let attempts: Int = await sink.attempts
        XCTAssertEqual(attempts, 1)
    }


    func testBooleanAndStringFieldsEncodeAsJsonValues() throws {
        let event: ImpulseTelemetryEvent = ImpulseTelemetryEvent(
            name: .networkFailures,
            time: fixedTime,
            fields: [
                "enabled": .bool(true),
                "variant": .string("arm-b"),
            ]
        )
        let request: [UInt8] = try ImpulseTelemetryEncoding.saveAppLogRequest(events: [event])

        XCTAssertTrue(containsSubsequence(request, Array("arm-b".utf8)))
        XCTAssertTrue(containsSubsequence(request, [0x6a, 0x5e, 0x34, 0xc7]))
        XCTAssertTrue(containsSubsequence(request, [0xb5, 0x75, 0x72, 0x99]))
        XCTAssertTrue(containsSubsequence(request, [0x7a, 0x76, 0x1e, 0xb7]))
    }


    private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }

        for start: Int in 0 ... (haystack.count - needle.count) where Array(haystack[start ..< start + needle.count]) == needle {
            return true
        }

        return false
    }
}
