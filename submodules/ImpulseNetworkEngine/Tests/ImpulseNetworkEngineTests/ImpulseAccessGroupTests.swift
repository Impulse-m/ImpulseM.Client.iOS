import XCTest
@testable import ImpulseNetworkEngine


final class ImpulseAccessGroupTests: XCTestCase {
    func testEmptyAccessGroupBecomesNil() {
        XCTAssertNil(ImpulseNetworkEngineFactory.normalizedAccessGroup(""))
    }


    func testMissingAccessGroupStaysNil() {
        XCTAssertNil(ImpulseNetworkEngineFactory.normalizedAccessGroup(nil))
    }


    func testNamedAccessGroupIsKept() {
        XCTAssertEqual(ImpulseNetworkEngineFactory.normalizedAccessGroup("test.group"), "test.group")
    }
}
