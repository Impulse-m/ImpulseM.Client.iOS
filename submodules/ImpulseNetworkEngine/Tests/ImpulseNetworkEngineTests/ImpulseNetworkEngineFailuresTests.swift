import XCTest
import ImpulseTransport
import MtProtoKit
import TelegramCore
@testable import ImpulseNetworkEngine


final class ImpulseNetworkEngineFailuresTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ImpulseEngineTestLogger.install()
    }


    func testFloodWaitIsRetryableExceptSlowModeAndStoryLimits() {
        XCTAssertTrue(ImpulseNetworkEngineFailures.isFlood(ImpulseRpcError(code: 420, text: "FLOOD_WAIT_3", temporary: false)))
        XCTAssertTrue(ImpulseNetworkEngineFailures.isFlood(ImpulseRpcError(code: 420, text: "FLOOD_PREMIUM_WAIT_60", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isFlood(ImpulseRpcError(code: 420, text: "SLOWMODE_WAIT_5", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isFlood(ImpulseRpcError(code: 420, text: "STORY_SEND_FLOOD", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isFlood(ImpulseRpcError(code: 400, text: "FLOOD_WAIT_3", temporary: false)))
    }


    func testServerErrorsAreFiveHundredAndNegativeFiveHundredOnly() {
        XCTAssertTrue(ImpulseNetworkEngineFailures.isServerError(ImpulseRpcError(code: 500, text: "INTERNAL", temporary: false)))
        XCTAssertTrue(ImpulseNetworkEngineFailures.isServerError(ImpulseRpcError(code: -500, text: "INTERNAL", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isServerError(ImpulseRpcError(code: -123, text: "RETRY_LIMIT", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isServerError(ImpulseRpcError(code: 503, text: "UNAVAILABLE", temporary: true)))
    }


    func testOnlyTheExactAnswerLostTextIsAnAnswerLost() {
        XCTAssertTrue(ImpulseNetworkEngineFailures.isAnswerLost(ImpulseRpcError(code: 500, text: "PROTOCOL_ERROR_ANSWER_LOST", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isAnswerLost(ImpulseRpcError(code: 400, text: "PROTOCOL_ERROR_ANSWER_LOST", temporary: false)))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isAnswerLost(ImpulseRpcError(code: 500, text: "PROTOCOL_ERROR_ANSWER", temporary: false)))
    }


    func testParsingFailureIsTheTransportsParsingError() {
        XCTAssertTrue(ImpulseNetworkEngineFailures.isParsingFailure(ImpulseNetworkSession.tlParsingError))
        XCTAssertFalse(ImpulseNetworkEngineFailures.isParsingFailure(ImpulseRpcError(code: 500, text: "INTERNAL", temporary: false)))
    }


    func testRpcErrorKeepsTheCodeAndTheTextAsReceived() {
        let mapped: MTRpcError = ImpulseNetworkEngineFailures.rpcError(ImpulseRpcError(code: 420, text: "FLOOD_WAIT_3", temporary: false))
        XCTAssertEqual(mapped.errorCode, 420)
        XCTAssertEqual(mapped.errorDescription, "FLOOD_WAIT_3")
    }


    func testErrorStateKeepsServerErrorsOfEarlierSubmissions() {
        var state: ImpulseNetworkErrorState = ImpulseNetworkErrorState()
        _ = state.applyServerError()
        state.didResubmit()
        let context: NetworkEngineErrorContext = state.applyServerError()
        XCTAssertEqual(context.internalServerErrorCount, 2)
    }


    func testErrorStateCountsParseFailuresAndFloodWaits() {
        var state: ImpulseNetworkErrorState = ImpulseNetworkErrorState()
        _ = state.applyParseFailure()
        let context: NetworkEngineErrorContext = state.applyFlood(seconds: 7, text: "FLOOD_WAIT_7")
        XCTAssertEqual(context.internalServerErrorCount, 1)
        XCTAssertEqual(context.floodWaitSeconds, 7)
        XCTAssertEqual(context.floodWaitErrorText, "FLOOD_WAIT_7")
    }
}
