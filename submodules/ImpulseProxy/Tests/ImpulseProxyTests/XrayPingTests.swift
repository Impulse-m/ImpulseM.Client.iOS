import Foundation
import XCTest
@testable import ImpulseProxy


/// Ordered record of the events a ping round produces (libXray calls, core stop and restart).
final class XrayPingEventLog: @unchecked Sendable {
    private(set) var entries: [String] = []


    func append(
        _ entry: String
    ) {
        entries.append(entry)
    }
}


/// Records the pauses requested by the ping helper instead of sleeping.
final class XrayPingPauseRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []


    func record(
        _ milliseconds: Int
    ) {
        values.append(milliseconds)
    }
}


/// Answers queued responses in order and records every request. Returns nil once the queue is empty.
final class QueuedXrayBridge: LibXrayBridge, @unchecked Sendable {
    private(set) var requests: [String] = []
    private var responses: [String]
    private let events: XrayPingEventLog


    init(
        responses: [String],
        events: XrayPingEventLog
    ) {
        self.responses = responses
        self.events = events
    }


    func invoke(
        requestJSON: String
    ) -> String? {
        requests.append(requestJSON)
        events.append("call")
        guard !responses.isEmpty else {
            return nil
        }
        return responses.removeFirst()
    }
}


final class RecordingXrayCoreLifecycle: XrayCoreLifecycle, @unchecked Sendable {
    private let events: XrayPingEventLog
    private let failOnStop: Bool


    init(
        events: XrayPingEventLog,
        failOnStop: Bool
    ) {
        self.events = events
        self.failOnStop = failOnStop
    }


    func stopCore() throws {
        events.append("stop")
        if failOnStop {
            throw XrayPingTestError.stopFailed
        }
    }


    func restartCore() throws {
        events.append("restart")
    }
}


enum XrayPingTestError: Error {
    case stopFailed
}


final class XrayPingTests: XCTestCase {
    private static let outboundTag: String = "proxy"


    func testBatchModeSendsChunksOfFiveAndKeepsOrder() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10, 11, 12, 13, 14]),
                XrayPingTests.batchResponse([20, 21, 22, 23, 24]),
                XrayPingTests.batchResponse([30, 31]),
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var offsets: [Int] = []
        var all: [XrayPingResult] = []
        ping.pingInChunks(
            configs: XrayPingTests.configs(12),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: XrayPing.maxBatchSize,
            pauseMillis: 0,
            onChunk: { (offset: Int, results: [XrayPingResult]) -> Bool in
                offsets.append(offset)
                all.append(contentsOf: results)
                return true
            }
        )
        XCTAssertEqual(bridge.requests.count, 3)
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[0]), ["c0", "c1", "c2", "c3", "c4"])
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[1]), ["c5", "c6", "c7", "c8", "c9"])
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[2]), ["c10", "c11"])
        XCTAssertEqual(offsets, [0, 5, 10])
        XCTAssertEqual(all.map { (result: XrayPingResult) -> Int in result.delay }, [10, 11, 12, 13, 14, 20, 21, 22, 23, 24, 30, 31])
        XCTAssertTrue(all.allSatisfy { (result: XrayPingResult) -> Bool in result.error == nil })
    }


    func testChunkSizeIsClampedToBatchLimit() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([1, 2, 3, 4, 5]),
                XrayPingTests.batchResponse([6, 7]),
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        ping.pingInChunks(
            configs: XrayPingTests.configs(7),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 50,
            pauseMillis: 0,
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(bridge.requests.count, 2)
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[0]).count, 5)
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[1]).count, 2)
    }


    func testSequentialRoundMakesOneCallPerConfig() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10]),
                XrayPingTests.batchResponse([20]),
                XrayPingTests.batchResponse([30]),
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.pingMode = "sequential"
        try ping.pingRound(
            configs: XrayPingTests.configs(3),
            outboundTag: XrayPingTests.outboundTag,
            advanced: advanced,
            coreRunning: false,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(bridge.requests.count, 3)
        XCTAssertEqual(events.entries, ["call", "call", "call"])
        XCTAssertEqual(try XrayPingTests.sentConfigs(bridge.requests[2]), ["c2"])
    }


    func testPausesOnlyBetweenChunks() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10]),
                XrayPingTests.batchResponse([20]),
                XrayPingTests.batchResponse([30]),
            ],
            events: events
        )
        let pauses: XrayPingPauseRecorder = XrayPingPauseRecorder()
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (milliseconds: Int) -> Void in pauses.record(milliseconds) }
        )
        ping.pingInChunks(
            configs: XrayPingTests.configs(3),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 1,
            pauseMillis: 60,
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(bridge.requests.count, 3)
        XCTAssertEqual(pauses.values, [60, 60])
    }


    func testZeroPauseNeverPauses() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10]),
                XrayPingTests.batchResponse([20]),
            ],
            events: events
        )
        let pauses: XrayPingPauseRecorder = XrayPingPauseRecorder()
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (milliseconds: Int) -> Void in pauses.record(milliseconds) }
        )
        ping.pingInChunks(
            configs: XrayPingTests.configs(2),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 1,
            pauseMillis: 0,
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertTrue(pauses.values.isEmpty)
    }


    func testFailedChunkReportsErrorAndNextChunkStillRuns() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10, 11, 12, 13, 14]),
                "{\"success\":false,\"error\":\"boom\"}",
                XrayPingTests.batchResponse([30, 31]),
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var all: [XrayPingResult] = []
        ping.pingInChunks(
            configs: XrayPingTests.configs(12),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 5,
            pauseMillis: 0,
            onChunk: { (_: Int, results: [XrayPingResult]) -> Bool in
                all.append(contentsOf: results)
                return true
            }
        )
        XCTAssertEqual(bridge.requests.count, 3)
        XCTAssertEqual(all.count, 12)
        XCTAssertEqual(all[0].delay, 10)
        for index: Int in 5..<10 {
            XCTAssertEqual(all[index].delay, -1)
            XCTAssertEqual(all[index].error, "boom")
        }
        XCTAssertEqual(all[10].delay, 30)
        XCTAssertEqual(all[11].delay, 31)
    }


    func testMalformedChunkReportsMinusOneWithText() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                "not json",
                XrayPingTests.batchResponse([30]),
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var all: [XrayPingResult] = []
        ping.pingInChunks(
            configs: XrayPingTests.configs(2),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 1,
            pauseMillis: 0,
            onChunk: { (_: Int, results: [XrayPingResult]) -> Bool in
                all.append(contentsOf: results)
                return true
            }
        )
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].delay, -1)
        XCTAssertNotNil(all[0].error)
        XCTAssertEqual(all[1].delay, 30)
    }


    func testMissingResultEntriesAreMinusOneWithoutText() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([120])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var all: [XrayPingResult] = []
        ping.pingInChunks(
            configs: XrayPingTests.configs(2),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 5,
            pauseMillis: 0,
            onChunk: { (_: Int, results: [XrayPingResult]) -> Bool in
                all.append(contentsOf: results)
                return true
            }
        )
        XCTAssertEqual(all, [XrayPingResult(delay: 120, error: nil), XrayPingResult(delay: -1, error: nil)])
    }


    func testPerItemErrorTextIsKept() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                "{\"success\":true,\"data\":{\"results\":[{\"success\":true,\"delay\":120},{\"success\":false,\"delay\":0,\"error\":\"timeout\"}]}}",
            ],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        var all: [XrayPingResult] = []
        ping.pingInChunks(
            configs: XrayPingTests.configs(2),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 5,
            pauseMillis: 0,
            onChunk: { (_: Int, results: [XrayPingResult]) -> Bool in
                all.append(contentsOf: results)
                return true
            }
        )
        XCTAssertEqual(all, [XrayPingResult(delay: 120, error: nil), XrayPingResult(delay: -1, error: "timeout")])
    }


    func testListenerReturningFalseStopsBeforeNextChunk() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([10, 11, 12, 13, 14])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        ping.pingInChunks(
            configs: XrayPingTests.configs(12),
            outboundTag: XrayPingTests.outboundTag,
            url: "https://example.com",
            timeoutSeconds: 5,
            chunkSize: 5,
            pauseMillis: 0,
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in false }
        )
        XCTAssertEqual(bridge.requests.count, 1)
    }


    func testRunningCoreIsStoppedPingedAndRestarted() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([10, 20, 30])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        try ping.pingRound(
            configs: XrayPingTests.configs(3),
            outboundTag: XrayPingTests.outboundTag,
            advanced: ImpulseProxyState.Advanced(),
            coreRunning: true,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(events.entries, ["stop", "call", "restart"])
    }


    func testStoppedCoreIsNotStarted() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([10])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        try ping.pingRound(
            configs: XrayPingTests.configs(1),
            outboundTag: XrayPingTests.outboundTag,
            advanced: ImpulseProxyState.Advanced(),
            coreRunning: false,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(events.entries, ["call"])
    }


    func testRestartStillRunsWhenListenerStopsEarly() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([10, 11, 12, 13, 14])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        try ping.pingRound(
            configs: XrayPingTests.configs(12),
            outboundTag: XrayPingTests.outboundTag,
            advanced: ImpulseProxyState.Advanced(),
            coreRunning: true,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in false }
        )
        XCTAssertEqual(bridge.requests.count, 1)
        XCTAssertEqual(events.entries, ["stop", "call", "restart"])
    }


    func testFailedStopSkipsPingAndThrows() {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [XrayPingTests.batchResponse([10])],
            events: events
        )
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        XCTAssertThrowsError(
            try ping.pingRound(
                configs: XrayPingTests.configs(1),
                outboundTag: XrayPingTests.outboundTag,
                advanced: ImpulseProxyState.Advanced(),
                coreRunning: true,
                lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: true),
                onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
            )
        )
        XCTAssertTrue(bridge.requests.isEmpty)
    }


    func testEmptyRoundTouchesNothing() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(responses: [], events: events)
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (_: Int) -> Void in }
        )
        try ping.pingRound(
            configs: [],
            outboundTag: XrayPingTests.outboundTag,
            advanced: ImpulseProxyState.Advanced(),
            coreRunning: true,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertTrue(events.entries.isEmpty)
    }


    func testRoundSendsAdvancedTimeoutUrlTagAndPausesFromSettings() throws {
        let events: XrayPingEventLog = XrayPingEventLog()
        let bridge: QueuedXrayBridge = QueuedXrayBridge(
            responses: [
                XrayPingTests.batchResponse([10]),
                XrayPingTests.batchResponse([20]),
            ],
            events: events
        )
        let pauses: XrayPingPauseRecorder = XrayPingPauseRecorder()
        let ping: XrayPing = XrayPing(
            client: LibXrayClient(bridge: bridge),
            pause: { (milliseconds: Int) -> Void in pauses.record(milliseconds) }
        )
        var advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        advanced.pingMode = "sequential"
        advanced.pingPauseMillis = 25
        advanced.pingTimeoutSeconds = 7
        advanced.pingUrl = "https://example.com/204"
        try ping.pingRound(
            configs: XrayPingTests.configs(2),
            outboundTag: XrayPingTests.outboundTag,
            advanced: advanced,
            coreRunning: false,
            lifecycle: RecordingXrayCoreLifecycle(events: events, failOnStop: false),
            onChunk: { (_: Int, _: [XrayPingResult]) -> Bool in true }
        )
        XCTAssertEqual(pauses.values, [25])
        let payload: [String: Any] = try XrayPingTests.payload(bridge.requests[0])
        XCTAssertEqual(payload["timeout"] as? Int, 7)
        XCTAssertEqual(payload["url"] as? String, "https://example.com/204")
        let sentItems: [[String: Any]] = try XCTUnwrap(payload["configs"] as? [[String: Any]])
        XCTAssertEqual(sentItems.first?["outboundTag"] as? String, XrayPingTests.outboundTag)
    }


    func testPingOnlyChangesDoNotRestartCore() {
        let previous: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        var next: ImpulseProxyState.Advanced = previous
        next.pingMode = "sequential"
        next.pingPauseMillis = 500
        next.pingTimeoutSeconds = 12
        next.pingUrl = "https://example.com/other"
        next.pingSkipWhileConnected = false
        XCTAssertFalse(XrayPing.restartRequired(previous: previous, next: next))
    }


    func testCoreAffectingChangesRestartCore() {
        let previous: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()
        var dns: ImpulseProxyState.Advanced = previous
        dns.dnsMode = "google"
        XCTAssertTrue(XrayPing.restartRequired(previous: previous, next: dns))
        var mux: ImpulseProxyState.Advanced = previous
        mux.muxEnabled = true
        XCTAssertTrue(XrayPing.restartRequired(previous: previous, next: mux))
    }


    private static func configs(
        _ count: Int
    ) -> [String] {
        return (0..<count).map { (index: Int) -> String in
            return "c\(index)"
        }
    }


    private static func batchResponse(
        _ delays: [Int]
    ) -> String {
        let items: [String] = delays.map { (delay: Int) -> String in
            return "{\"success\":true,\"delay\":\(delay)}"
        }
        return "{\"success\":true,\"data\":{\"results\":[" + items.joined(separator: ",") + "]}}"
    }


    private static func payload(
        _ request: String
    ) throws -> [String: Any] {
        let object: Any = try JSONSerialization.jsonObject(with: Data(request.utf8), options: [])
        let envelope: [String: Any] = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(envelope["payload"] as? [String: Any])
    }


    private static func sentConfigs(
        _ request: String
    ) throws -> [String] {
        let payloadObject: [String: Any] = try payload(request)
        let items: [[String: Any]] = try XCTUnwrap(payloadObject["configs"] as? [[String: Any]])
        return items.compactMap { (item: [String: Any]) -> String? in
            return item["xrayJson"] as? String
        }
    }
}
