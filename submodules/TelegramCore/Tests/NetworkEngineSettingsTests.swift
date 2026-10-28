import XCTest
import Foundation
@testable import TelegramCore

final class NetworkEngineSettingsTests: XCTestCase {
    private func decodeSettings(json: String) throws -> NetworkEngineSettings {
        let data: Data = Data(json.utf8)
        let decoder: JSONDecoder = JSONDecoder()
        return try decoder.decode(NetworkEngineSettings.self, from: data)
    }

    func testDefaultSettingsUseImpulseEngine() {
        XCTAssertEqual(NetworkEngineSettings.defaultSettings.engine, .impulse)
    }

    func testDecodesStoredImpulseValue() throws {
        let settings: NetworkEngineSettings = try self.decodeSettings(json: "{\"engine_v2\":\"impulse\"}")

        XCTAssertEqual(settings.engine, .impulse)
    }

    func testDecodesOldRustValueAsImpulse() throws {
        let settings: NetworkEngineSettings = try self.decodeSettings(json: "{\"engine_v2\":\"rust\"}")

        XCTAssertEqual(settings.engine, .impulse)
    }

    func testDecodesOldMtProtoKitValueAsImpulse() throws {
        let settings: NetworkEngineSettings = try self.decodeSettings(json: "{\"engine_v2\":\"mtProtoKit\"}")

        XCTAssertEqual(settings.engine, .impulse)
    }

    func testDecodesUnknownValueAsImpulse() throws {
        let settings: NetworkEngineSettings = try self.decodeSettings(json: "{\"engine_v2\":\"unknown\"}")

        XCTAssertEqual(settings.engine, .impulse)
    }

    func testDecodesMissingValueAsImpulse() throws {
        let settings: NetworkEngineSettings = try self.decodeSettings(json: "{}")

        XCTAssertEqual(settings.engine, .impulse)
    }

    func testEncodesImpulseRawValue() throws {
        let encoder: JSONEncoder = JSONEncoder()
        let data: Data = try encoder.encode(NetworkEngineSettings(engine: .impulse))
        let object: [String: String] = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(object["engine_v2"], "impulse")
    }
}
