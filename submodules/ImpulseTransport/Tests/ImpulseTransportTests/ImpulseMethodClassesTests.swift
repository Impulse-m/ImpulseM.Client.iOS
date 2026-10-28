import XCTest
@testable import ImpulseTransport


final class ImpulseMethodClassesTests: XCTestCase {
    func testIdentitySocketAllowsEveryIdentityMethod() {
        for method in ImpulseMethodClasses.identitySocketMethods {
            XCTAssertTrue(ImpulseMethodClasses.allowed(signedIn: false, method: method), method)
        }
    }


    func testIdentitySocketRefusesSessionMethods() {
        let refused: [String] = [
            "messages.sendMessage",
            "users.getFullUser",
            "account.updateProfile",
        ]

        for method in refused {
            XCTAssertFalse(ImpulseMethodClasses.allowed(signedIn: false, method: method), method)
        }
    }


    func testIdentitySocketRefusesMediaMethods() {
        for method in ImpulseMethodClasses.mediaMethods {
            XCTAssertFalse(ImpulseMethodClasses.allowed(signedIn: false, method: method), method)
        }
    }


    func testIdentitySocketSetIsDisjointUnionOfItsParts() {
        let expectedCount: Int = ImpulseMethodClasses.loginOnlyMethods.count
            + ImpulseMethodClasses.dualUseMethods.count
            + ImpulseMethodClasses.pendingMethods.count
            + ImpulseMethodClasses.publicMethods.count
            + ImpulseMethodClasses.identityControlMethods.count

        XCTAssertEqual(ImpulseMethodClasses.identitySocketMethods.count, expectedCount)
        XCTAssertEqual(expectedCount, 38)
    }


    func testSignedInSocketRefusesLoginOnlyMethods() {
        for method in ImpulseMethodClasses.loginOnlyMethods {
            XCTAssertFalse(ImpulseMethodClasses.allowed(signedIn: true, method: method), method)
        }
    }


    func testSignedInSocketAllowsSessionAndPublicMethods() {
        let allowedMethods: [String] = [
            "messages.sendMessage",
            "upload.saveFilePart",
            "help.getConfig",
            "account.deleteAccount",
        ]

        for method in allowedMethods {
            XCTAssertTrue(ImpulseMethodClasses.allowed(signedIn: true, method: method), method)
        }
    }


    func testMediaMethodsAreNotIdentitySocketMethods() {
        for method in ImpulseMethodClasses.mediaMethods {
            XCTAssertFalse(ImpulseMethodClasses.identitySocketMethods.contains(method), method)
        }
    }
}
