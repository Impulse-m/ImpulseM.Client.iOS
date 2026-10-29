import XCTest
import Foundation
@testable import TelegramCore

final class ImpulseProxySettingsStateTests: XCTestCase {
    private func decodeState(json: String) throws -> ImpulseProxyState {
        let decoder: JSONDecoder = JSONDecoder()
        return try decoder.decode(ImpulseProxyState.self, from: Data(json.utf8))
    }

    func testDefaultStateKeepsBothTogglesOn() {
        let state: ImpulseProxyState = ImpulseProxyState()

        XCTAssertFalse(state.enabled)
        XCTAssertTrue(state.useForTransport)
        XCTAssertTrue(state.useForCalls)
        XCTAssertNil(state.selectedId)
    }

    func testMissingCallsToggleDecodesAsOn() throws {
        let state: ImpulseProxyState = try self.decodeState(json: "{\"v\":1,\"enabled\":true}")

        XCTAssertTrue(state.enabled)
        XCTAssertTrue(state.useForCalls)
        XCTAssertTrue(state.useForTransport)
    }

    func testMissingTransportToggleDecodesAsOn() throws {
        let state: ImpulseProxyState = try self.decodeState(json: "{\"v\":1,\"useForCalls\":false}")

        XCTAssertTrue(state.useForTransport)
        XCTAssertFalse(state.useForCalls)
    }

    func testExplicitCallsToggleOffIsKept() throws {
        let state: ImpulseProxyState = try self.decodeState(json: "{\"v\":1,\"useForTransport\":true,\"useForCalls\":false}")

        XCTAssertTrue(state.useForTransport)
        XCTAssertFalse(state.useForCalls)
    }

    func testBothTogglesOffInitializerKeepsTransportOn() {
        let state: ImpulseProxyState = ImpulseProxyState(useForTransport: false, useForCalls: false)

        XCTAssertTrue(state.useForTransport)
        XCTAssertFalse(state.useForCalls)
    }

    func testSetTogglesRejectsBothOff() {
        var state: ImpulseProxyState = ImpulseProxyState()
        let changed: Bool = state.setToggles(useForTransport: false, useForCalls: false)

        XCTAssertFalse(changed)
        XCTAssertTrue(state.useForTransport)
        XCTAssertTrue(state.useForCalls)
    }

    func testSetTogglesAcceptsTransportOnlyMode() {
        var state: ImpulseProxyState = ImpulseProxyState()
        let changed: Bool = state.setToggles(useForTransport: true, useForCalls: false)

        XCTAssertTrue(changed)
        XCTAssertTrue(state.useForTransport)
        XCTAssertFalse(state.useForCalls)
    }

    func testLegacyProxySettingsRecordDoesNotDecodeAsState() {
        let legacy: String = "{\"enabled\":1,\"servers\":[],\"useForCalls\":1}"

        XCTAssertThrowsError(try self.decodeState(json: legacy))
    }

    func testVersionedStateRoundTrips() throws {
        var state: ImpulseProxyState = ImpulseProxyState(
            enabled: true,
            selectedId: "0123456789abcdef01234567",
            manual: [
                ImpulseProxyState.Server(
                    id: "0123456789abcdef01234567",
                    name: "Node",
                    host: "example.com",
                    port: 443,
                    network: "raw",
                    security: "tls",
                    outboundJson: "{}",
                    shareLink: "vless://user@example.com:443"
                )
            ]
        )
        state.advanced.muxConcurrency = 16

        let data: Data = try JSONEncoder().encode(state)
        let decoded: ImpulseProxyState = try JSONDecoder().decode(ImpulseProxyState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.advanced.muxConcurrency, 16)
    }

    func testOutOfRangeAdvancedValuesAreSanitized() throws {
        let state: ImpulseProxyState = try self.decodeState(json: "{\"v\":1,\"advanced\":{\"muxConcurrency\":999,\"pingTimeoutSeconds\":0,\"fragmentMode\":\"bogus\"}}")

        XCTAssertEqual(state.advanced.muxConcurrency, 8)
        XCTAssertEqual(state.advanced.pingTimeoutSeconds, 5)
        XCTAssertEqual(state.advanced.fragmentMode, "off")
    }

    func testAdvancedDefaultsMatchTheModel() {
        let advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()

        XCTAssertEqual(advanced.fragmentPackets, "tlshello")
        XCTAssertEqual(advanced.fragmentLength, "100-200")
        XCTAssertEqual(advanced.fragmentInterval, "10-20")
        XCTAssertEqual(advanced.muxConcurrency, 8)
        XCTAssertEqual(advanced.dnsMode, "system")
        XCTAssertEqual(advanced.pingMode, "batch")
        XCTAssertEqual(advanced.pingPauseMillis, 0)
        XCTAssertEqual(advanced.pingTimeoutSeconds, 5)
        XCTAssertEqual(advanced.pingUrl, "https://www.gstatic.com/generate_204")
        XCTAssertTrue(advanced.pingSkipWhileConnected)
    }

    func testLegacyProxySettingsCallsToggleDefaultsToOn() throws {
        let decoder: JSONDecoder = JSONDecoder()
        let settings: ProxySettings = try decoder.decode(ProxySettings.self, from: Data("{\"enabled\":0,\"servers\":[]}".utf8))

        XCTAssertTrue(settings.useForCalls)
        XCTAssertTrue(ProxySettings.defaultSettings.useForCalls)
    }
}
