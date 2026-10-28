import XCTest
@testable import ImpulseTransport


final class ImpulseCarrierTests: XCTestCase {
    func testMediaMethodsGoToMediaCarrier() {
        for method in ImpulseMethodClasses.mediaMethods {
            XCTAssertEqual(ImpulseCarrier.route(method: method, signedIn: true), .media, method)
        }
    }


    func testCdnAndFileHashesGoToUpdateSocket() {
        let methods: [String] = [
            "upload.getCdnFile",
            "upload.getFileHashes",
        ]

        for method in methods {
            XCTAssertEqual(ImpulseCarrier.route(method: method, signedIn: true), .update, method)
        }
    }


    func testOrdinaryMethodGoesToUpdateSocketWhenSignedIn() {
        XCTAssertEqual(ImpulseCarrier.route(method: "messages.sendMessage", signedIn: true), .update)
        XCTAssertEqual(ImpulseCarrier.route(method: "help.getConfig", signedIn: true), .update)
    }


    func testPoolOnlyMethodsGoToPool() {
        let methods: [String] = [
            "connectionIdentity",
            "refreshSession",
        ]

        for method in methods {
            XCTAssertEqual(ImpulseCarrier.route(method: method, signedIn: false), .pool, method)
            XCTAssertEqual(ImpulseCarrier.route(method: method, signedIn: true), .pool, method)
        }
    }


    func testIdentitySocketRefusesSessionMethodsLocally() {
        let refused: [String] = [
            "messages.sendMessage",
            "users.getFullUser",
            "account.updateProfile",
        ]

        for method in refused {
            XCTAssertEqual(
                ImpulseCarrier.route(method: method, signedIn: false),
                .refused(ImpulseCarrier.identityRefusalError),
                method
            )
        }
    }


    func testIdentitySocketRefusesMediaMethodsLocally() {
        for method in ImpulseMethodClasses.mediaMethods {
            XCTAssertEqual(
                ImpulseCarrier.route(method: method, signedIn: false),
                .refused(ImpulseCarrier.identityRefusalError),
                method
            )
        }
    }


    func testIdentitySocketAllowsIdentityMethodsOnUpdateSocket() {
        XCTAssertEqual(ImpulseCarrier.route(method: "initConnection", signedIn: false), .update)
        XCTAssertEqual(ImpulseCarrier.route(method: "help.getAppConfig", signedIn: false), .update)
        XCTAssertEqual(ImpulseCarrier.route(method: "auth.sendCode", signedIn: false), .update)
    }


    func testSignedInSocketRefusesLoginOnlyMethodsLocally() {
        for method in ImpulseMethodClasses.loginOnlyMethods {
            XCTAssertEqual(
                ImpulseCarrier.route(method: method, signedIn: true),
                .refused(ImpulseCarrier.identityRefusalError),
                method
            )
        }
    }


    func testIdentityRefusalIsLocalClientError() {
        let error: ImpulseRpcError = ImpulseCarrier.identityRefusalError

        XCTAssertEqual(error.code, 400)
        XCTAssertEqual(error.text, "CLIENT_IDENTITY_REFUSED")
        XCTAssertFalse(error.temporary)
        XCTAssertNotEqual(error.text, "METHOD_INVALID")
    }


    func testTakeoutIsNotAnsweredLocallyOnEitherSocket() {
        XCTAssertEqual(ImpulseCarrier.route(method: "invokeWithTakeout", signedIn: true), .update)
        XCTAssertEqual(ImpulseCarrier.route(method: "invokeWithTakeout", signedIn: false), .update)
    }


    func testTokenRefusalOnUpdateRouteMapsToAuthKeyUnregistered() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 0,
            appType: "",
            metadata: [:]
        )

        XCTAssertEqual(
            ImpulseCarrier.rpcError(from: failure, route: .update),
            ImpulseRpcError(code: 401, text: "AUTH_KEY_UNREGISTERED", temporary: false)
        )
    }


    func testTokenRefusalOnMediaRouteMapsToAuthTokenInvalid() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 103,
            appCode: 0,
            appType: "",
            metadata: [:]
        )

        XCTAssertEqual(
            ImpulseCarrier.rpcError(from: failure, route: .media),
            ImpulseRpcError(code: 400, text: "AUTH_TOKEN_INVALID", temporary: false)
        )
    }


    func testNetworkFailureIsNotRpcError() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 15,
            appCode: 0,
            appType: "",
            metadata: [:]
        )

        XCTAssertNil(ImpulseCarrier.rpcError(from: failure, route: .update))
        XCTAssertNil(ImpulseCarrier.rpcError(from: failure, route: .media))
        XCTAssertNil(ImpulseCarrier.rpcError(from: failure, route: .pool))
    }


    func testRefusedRouteAnswersItsOwnRefusal() {
        let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 0,
            appType: "",
            metadata: [:]
        )

        XCTAssertEqual(
            ImpulseCarrier.rpcError(from: failure, route: .refused(ImpulseCarrier.identityRefusalError)),
            ImpulseCarrier.identityRefusalError
        )
    }
}
