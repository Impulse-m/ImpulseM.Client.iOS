import XCTest
import TelegramApi
@testable import TelegramCore

final class CallSessionCustomParametersTests: XCTestCase {
    func testAbsentCustomParametersStayNil() {
        let value: String? = callSessionCustomParameters(nil)

        XCTAssertNil(value)
    }

    func testCustomParametersJSONIsKept() {
        let json: String = "{\"room\":\"call-room\",\"identity\":\"u1.2\"}"
        let value: String? = callSessionCustomParameters(.dataJSON(.init(data: json)))

        XCTAssertEqual(value, json)
    }
}
