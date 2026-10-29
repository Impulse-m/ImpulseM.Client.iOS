import XCTest
@testable import ImpulseTransport


final class ImpulseProxyConnectionProxyTests: XCTestCase {
    private let expectedKeys: Set<String> = [
        "HTTPEnable",
        "HTTPProxy",
        "HTTPPort",
        "HTTPSEnable",
        "HTTPSProxy",
        "HTTPSPort"
    ]


    func testNilRouteGivesNoDictionary() {
        XCTAssertNil(ImpulseProxyConnectionProxy.dictionary(for: nil))
    }


    func testRouteGivesExactKeySet() {
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil)
        let dictionary: [AnyHashable: Any]? = ImpulseProxyConnectionProxy.dictionary(for: route)
        let keys: Set<String> = Set((dictionary ?? [:]).keys.compactMap { (key: AnyHashable) -> String? in
            return key as? String
        })
        XCTAssertEqual(keys, expectedKeys)
        XCTAssertEqual(dictionary?.count, expectedKeys.count)
    }


    func testRouteSetsHttpAndHttpsEnableHostAndPort() {
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: nil, password: nil)
        let dictionary: [AnyHashable: Any] = ImpulseProxyConnectionProxy.dictionary(for: route) ?? [:]
        XCTAssertEqual(dictionary["HTTPEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPSEnable"] as? Int, 1)
        XCTAssertEqual(dictionary["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary["HTTPPort"] as? Int, 1080)
        XCTAssertEqual(dictionary["HTTPSPort"] as? Int, 1080)
    }


    func testBlackholeRouteGivesBlockingDictionaryNeverNil() {
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        let dictionary: [AnyHashable: Any]? = ImpulseProxyConnectionProxy.dictionary(for: route)
        XCTAssertNotNil(dictionary)
        XCTAssertEqual(dictionary?["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dictionary?["HTTPPort"] as? Int, 9)
        XCTAssertEqual(dictionary?["HTTPSPort"] as? Int, 9)
    }


    func testRouteWithCredentialsGivesNoCredentialKeys() {
        let route: ImpulseProxyRoute = ImpulseProxyRoute(host: "127.0.0.1", port: 1080, username: "user", password: "secret")
        let dictionary: [AnyHashable: Any]? = ImpulseProxyConnectionProxy.dictionary(for: route)
        let keys: Set<String> = Set((dictionary ?? [:]).keys.compactMap { (key: AnyHashable) -> String? in
            return key as? String
        })
        XCTAssertEqual(keys, expectedKeys)
    }
}
