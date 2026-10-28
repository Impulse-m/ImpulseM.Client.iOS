import XCTest
@testable import ImpulseTransport


final class ImpulseErrorsTests: XCTestCase {
    func testClassifyAuthTexts() {
        XCTAssertEqual(ImpulseErrors.classify(nil), .noAuthAction)
        XCTAssertEqual(ImpulseErrors.classify(rpc(401, "AUTH_KEY_UNREGISTERED")), .refreshAndRetry)
        XCTAssertEqual(ImpulseErrors.classify(rpc(401, "SESSION_REVOKED")), .forceLogout)
        XCTAssertEqual(ImpulseErrors.classify(rpc(401, "USER_DEACTIVATED")), .forceLogout)
        XCTAssertEqual(ImpulseErrors.classify(rpc(401, "SESSION_EXPIRED")), .forceLogout)
        XCTAssertEqual(ImpulseErrors.classify(rpc(400, "AUTH_TOKEN_EXPIRED")), .forceLogout)
        XCTAssertEqual(ImpulseErrors.classify(rpc(401, "AUTH_KEY_INVALID")), .forceLogout)
        XCTAssertEqual(ImpulseErrors.classify(rpc(420, "FLOOD_WAIT_5")), .noAuthAction)
    }


    func testFloodWaitSeconds() {
        XCTAssertEqual(ImpulseErrors.floodWaitSeconds(rpc(420, "FLOOD_WAIT_5")), 5)
        XCTAssertEqual(ImpulseErrors.floodWaitSeconds(rpc(420, "FLOOD_PREMIUM_WAIT_60")), 60)
        XCTAssertEqual(ImpulseErrors.floodWaitSeconds(rpc(420, "SLOWMODE_WAIT_900")), 900)
        XCTAssertNil(ImpulseErrors.floodWaitSeconds(rpc(420, "FLOOD_WAIT_x")))
        XCTAssertNil(ImpulseErrors.floodWaitSeconds(rpc(420, "FLOOD_WAIT_")))
        XCTAssertNil(ImpulseErrors.floodWaitSeconds(rpc(400, "AUTH_KEY_INVALID")))
        XCTAssertNil(ImpulseErrors.floodWaitSeconds(nil))
    }


    func testTokenRefusalUpdateFleet() {
        let failure: ImpulseCarrierFailure = sdk(103)
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .update),
            ImpulseRpcError(code: 401, text: "AUTH_KEY_UNREGISTERED", temporary: false)
        )
    }


    func testTokenRefusalMediaFleet() {
        let failure: ImpulseCarrierFailure = sdk(103)
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .media),
            ImpulseRpcError(code: 400, text: "AUTH_TOKEN_INVALID", temporary: false)
        )
    }


    func testTokenRefusalIsCheckedBeforeAppType() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 401,
            appType: "AUTH_KEY_UNREGISTERED",
            metadata: [:]
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .update),
            ImpulseRpcError(code: 401, text: "AUTH_KEY_UNREGISTERED", temporary: false)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .media),
            ImpulseRpcError(code: 400, text: "AUTH_TOKEN_INVALID", temporary: false)
        )
    }


    func testTokenExpiredAnswersAuthTokenExpired() {
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: sdk(109), fleet: .update),
            ImpulseRpcError(code: 400, text: "AUTH_TOKEN_EXPIRED", temporary: false)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: sdk(109), fleet: .media),
            ImpulseRpcError(code: 400, text: "AUTH_TOKEN_EXPIRED", temporary: false)
        )
    }


    func testMethodInvalidWithoutAppType() {
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: sdk(104), fleet: .update),
            ImpulseRpcError(code: 400, text: "METHOD_INVALID", temporary: false)
        )
    }


    func testOverloadedAndTooLargeAnswerInternalServerError() {
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: sdk(111), fleet: .update),
            ImpulseRpcError(code: 500, text: "INTERNAL_SERVER_ERROR", temporary: false)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: sdk(106), fleet: .update),
            ImpulseRpcError(code: 500, text: "INTERNAL_SERVER_ERROR", temporary: false)
        )
    }


    func testAppTypeKeepsRawTextAndServerCode() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 100,
            appCode: 420,
            appType: "FLOOD_WAIT_5",
            metadata: [:]
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .update),
            ImpulseRpcError(code: 420, text: "FLOOD_WAIT_5", temporary: false)
        )
    }


    func testAppTypeWithoutAppCodeIsBadRequest() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 100,
            appCode: 0,
            appType: "PEER_ID_INVALID",
            metadata: [:]
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .update),
            ImpulseRpcError(code: 400, text: "PEER_ID_INVALID", temporary: false)
        )
    }


    func testMigrateDcMetadataAnswers303() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 100,
            appCode: 420,
            appType: "PHONE_MIGRATE",
            metadata: ["migrate-dc": "2"]
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: failure, fleet: .update),
            ImpulseRpcError(code: 303, text: "PHONE_MIGRATE", temporary: false)
        )
    }


    func testBackendTransportFaultsAreTemporaryOnlyWhenNamed() {
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("UNAVAILABLE", 500), fleet: .update),
            ImpulseRpcError(code: 500, text: "UNAVAILABLE", temporary: true)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("DEADLINE_EXCEEDED", 500), fleet: .update),
            ImpulseRpcError(code: 500, text: "DEADLINE_EXCEEDED", temporary: true)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("UNKNOWN", 500), fleet: .update),
            ImpulseRpcError(code: 500, text: "UNKNOWN", temporary: false)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("INTERNAL", 500), fleet: .update),
            ImpulseRpcError(code: 500, text: "INTERNAL", temporary: false)
        )
    }


    func testBackendServerTextsAnswerInternalServerErrorWithoutAppCode() {
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("UNAVAILABLE", 0), fleet: .update),
            ImpulseRpcError(code: 500, text: "UNAVAILABLE", temporary: true)
        )
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: appType("UNKNOWN", 0), fleet: .update),
            ImpulseRpcError(code: 500, text: "UNKNOWN", temporary: false)
        )
    }


    func testNetworkFailuresAreNotRpcErrors() {
        let networkSdkCodes: [Int] = [15, 16, 17, 4, 12, 18, 100]
        for code: Int in networkSdkCodes {
            XCTAssertNil(ImpulseErrors.rpcError(from: sdk(code), fleet: .update), "SDK code \(code)")
        }
        XCTAssertNil(ImpulseErrors.rpcError(from: sdk(0), fleet: .update))
        XCTAssertNil(ImpulseErrors.rpcError(from: sdk(0), fleet: .media))
    }


    func testCancelledAndTokenRefusalPredicates() {
        XCTAssertTrue(ImpulseErrors.isCancelled(sdk(17)))
        XCTAssertFalse(ImpulseErrors.isCancelled(sdk(16)))
        XCTAssertTrue(ImpulseErrors.isTokenRefusal(sdk(103)))
        XCTAssertTrue(ImpulseErrors.isTokenRefusal(sdk(109)))
        XCTAssertFalse(ImpulseErrors.isTokenRefusal(sdk(104)))
    }


    private func rpc(_ code: Int, _ text: String) -> ImpulseRpcError {
        return ImpulseRpcError(code: code, text: text, temporary: false)
    }


    private func sdk(_ code: Int) -> ImpulseCarrierFailure {
        return ImpulseCarrierFailure(sdkCode: code, appCode: 0, appType: "", metadata: [:])
    }


    private func appType(_ text: String, _ code: Int) -> ImpulseCarrierFailure {
        return ImpulseCarrierFailure(sdkCode: 100, appCode: code, appType: text, metadata: [:])
    }
}
