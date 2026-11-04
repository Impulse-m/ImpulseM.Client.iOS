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


    func testDataProtectionItemQueryKeepsTheFlagAndTheAccessGroup() {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: "service",
            account: "account",
            accessGroup: "group.impulsem",
            usesDataProtectionKeychain: true
        )

        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "group.impulsem")
    }


    func testFileKeychainItemQueryHasNoDataProtectionAttributes() {
        let query: [String: Any] = ImpulseKeychainQuery.item(
            service: "service",
            account: "account",
            accessGroup: "group.impulsem",
            usesDataProtectionKeychain: false
        )

        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query[kSecAttrService as String] as? String, "service")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "account")
    }


    func testDataProtectionAdditionKeepsTheAccessibility() {
        let query: [String: Any] = ImpulseKeychainQuery.addition(
            service: "service",
            account: "account",
            accessGroup: nil,
            data: Data(),
            usesDataProtectionKeychain: true
        )

        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }


    func testFileKeychainAdditionHasNoDataProtectionAttributes() {
        let query: [String: Any] = ImpulseKeychainQuery.addition(
            service: "service",
            account: "account",
            accessGroup: "group.impulsem",
            data: Data(),
            usesDataProtectionKeychain: false
        )

        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertEqual(query[kSecValueData as String] as? Data, Data())
    }
}
