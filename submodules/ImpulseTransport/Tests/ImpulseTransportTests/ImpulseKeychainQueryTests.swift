import Foundation
import Security
import XCTest
@testable import ImpulseTransport


final class ImpulseKeychainQueryTests: XCTestCase {
    func testEmptyAccessGroupIsLeftOutOfTheItemQuery() {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: "service",
            account: "account",
            accessGroup: ""
        )

        XCTAssertNil(query[kSecAttrAccessGroup as String])
    }


    func testMissingAccessGroupIsLeftOutOfTheItemQuery() {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: "service",
            account: "account",
            accessGroup: nil
        )

        XCTAssertNil(query[kSecAttrAccessGroup as String])
    }


    func testNamedAccessGroupIsKeptInTheItemQuery() {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: "service",
            account: "account",
            accessGroup: "group.impulsem"
        )

        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "group.impulsem")
    }
}
