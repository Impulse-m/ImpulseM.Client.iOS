import XCTest
import TelegramCore
@testable import SettingsUI


final class ImpulseProxyAdvancedControllerTests: XCTestCase {
    func testStateDefaultsMatchContract() {
        let advanced: ImpulseProxyState.Advanced = ImpulseProxyState.Advanced()

        XCTAssertEqual(advanced, ImpulseProxyAdvancedRules.contractDefaults())
    }


    func testContractDefaultValues() {
        let advanced: ImpulseProxyState.Advanced = ImpulseProxyAdvancedRules.contractDefaults()

        XCTAssertEqual(advanced.fragmentMode, "off")
        XCTAssertEqual(advanced.fragmentPackets, "tlshello")
        XCTAssertEqual(advanced.fragmentLength, "100-200")
        XCTAssertEqual(advanced.fragmentInterval, "10-20")
        XCTAssertTrue(advanced.fragmentFromLink)
        XCTAssertEqual(advanced.fingerprint, "")
        XCTAssertFalse(advanced.muxEnabled)
        XCTAssertEqual(advanced.muxConcurrency, 8)
        XCTAssertEqual(advanced.keepAliveIdle, 0)
        XCTAssertEqual(advanced.keepAliveInterval, 0)
        XCTAssertFalse(advanced.tcpFastOpen)
        XCTAssertEqual(advanced.tcpMaxSeg, 0)
        XCTAssertEqual(advanced.dnsMode, "system")
        XCTAssertEqual(advanced.dnsCustom, "")
        XCTAssertEqual(advanced.pingMode, "batch")
        XCTAssertEqual(advanced.pingPauseMillis, 0)
        XCTAssertEqual(advanced.pingTimeoutSeconds, 5)
        XCTAssertEqual(advanced.pingUrl, "https://www.gstatic.com/generate_204")
        XCTAssertTrue(advanced.pingSkipWhileConnected)
    }


    func testPingSettingsDoNotRestartCore() {
        let previous: ImpulseProxyState.Advanced = ImpulseProxyAdvancedRules.contractDefaults()

        var pingMode: ImpulseProxyState.Advanced = previous
        pingMode.pingMode = "sequential"
        XCTAssertFalse(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: pingMode))

        var pingPause: ImpulseProxyState.Advanced = previous
        pingPause.pingPauseMillis = 500
        XCTAssertFalse(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: pingPause))

        var pingTimeout: ImpulseProxyState.Advanced = previous
        pingTimeout.pingTimeoutSeconds = 12
        XCTAssertFalse(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: pingTimeout))

        var pingUrl: ImpulseProxyState.Advanced = previous
        pingUrl.pingUrl = "https://example.com/204"
        XCTAssertFalse(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: pingUrl))

        var pingSkip: ImpulseProxyState.Advanced = previous
        pingSkip.pingSkipWhileConnected = false
        XCTAssertFalse(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: pingSkip))
    }


    func testCoreSettingsRestartCore() {
        let previous: ImpulseProxyState.Advanced = ImpulseProxyAdvancedRules.contractDefaults()

        var fragmentMode: ImpulseProxyState.Advanced = previous
        fragmentMode.fragmentMode = "classic"
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: fragmentMode))

        var fingerprint: ImpulseProxyState.Advanced = previous
        fingerprint.fingerprint = "firefox"
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: fingerprint))

        var mux: ImpulseProxyState.Advanced = previous
        mux.muxEnabled = true
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: mux))

        var fastOpen: ImpulseProxyState.Advanced = previous
        fastOpen.tcpFastOpen = true
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: fastOpen))

        var dns: ImpulseProxyState.Advanced = previous
        dns.dnsMode = "google"
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: dns))

        var keepAlive: ImpulseProxyState.Advanced = previous
        keepAlive.keepAliveIdle = 60
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: keepAlive))

        var fromLink: ImpulseProxyState.Advanced = previous
        fromLink.fragmentFromLink = false
        XCTAssertTrue(ImpulseProxyAdvancedRules.restartRequired(previous: previous, next: fromLink))
    }
}
