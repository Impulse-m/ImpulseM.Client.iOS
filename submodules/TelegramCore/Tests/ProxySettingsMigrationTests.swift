import XCTest
@testable import TelegramCore

final class ProxySettingsMigrationTests: XCTestCase {
    private func legacySettings() -> ProxySettings {
        return ProxySettings(
            enabled: true,
            servers: [
                ProxyServerSettings(host: "proxy.example.com", port: 1080, connection: .socks5(username: nil, password: nil))
            ],
            activeServer: nil,
            useForCalls: true
        )
    }

    func testLegacyRecordIsNotReadAsTheImpulseState() throws {
        let legacy: PreferencesEntry = try XCTUnwrap(PreferencesEntry(legacySettings()))
        XCTAssertNil(legacy.get(ImpulseProxyState.self))
    }

    func testLegacyRecordIsDroppedOnceAndTheNoticeIsDue() throws {
        let legacy: PreferencesEntry = try XCTUnwrap(PreferencesEntry(legacySettings()))
        let first: ProxySettingsMigrationStep = proxySettingsMigrationStep(proxySettings: legacy, notice: nil)

        XCTAssertNil(first.proxySettings)
        XCTAssertTrue(first.legacyRecordDropped)
        let firstNotice: ProxySettingsMigrationNotice = try XCTUnwrap(first.notice)
        XCTAssertTrue(firstNotice.legacyRecordDropped)
        XCTAssertFalse(firstNotice.dismissed)

        // The next run finds no record and a stored notice: nothing changes and nothing is dropped again.
        let second: ProxySettingsMigrationStep = proxySettingsMigrationStep(proxySettings: first.proxySettings, notice: firstNotice)
        XCTAssertNil(second.proxySettings)
        XCTAssertFalse(second.legacyRecordDropped)
        XCTAssertNil(second.notice)
    }

    func testLegacyRecordFoundAfterTheMigrationRanIsLeftAlone() throws {
        let legacy: PreferencesEntry = try XCTUnwrap(PreferencesEntry(legacySettings()))
        let step: ProxySettingsMigrationStep = proxySettingsMigrationStep(
            proxySettings: legacy,
            notice: ProxySettingsMigrationNotice(legacyRecordDropped: false)
        )

        XCTAssertEqual(step.proxySettings, legacy)
        XCTAssertFalse(step.legacyRecordDropped)
        XCTAssertNil(step.notice)
    }

    func testFreshInstallMarksTheMigrationDoneWithoutANotice() {
        let step: ProxySettingsMigrationStep = proxySettingsMigrationStep(proxySettings: nil, notice: nil)

        XCTAssertNil(step.proxySettings)
        XCTAssertFalse(step.legacyRecordDropped)
        XCTAssertEqual(step.notice, ProxySettingsMigrationNotice(legacyRecordDropped: false))
    }

    func testImpulseStateRecordIsKeptAndNoNoticeIsDue() throws {
        let state: PreferencesEntry = try XCTUnwrap(PreferencesEntry(ImpulseProxyState()))
        let step: ProxySettingsMigrationStep = proxySettingsMigrationStep(proxySettings: state, notice: nil)

        XCTAssertEqual(step.proxySettings, state)
        XCTAssertFalse(step.legacyRecordDropped)
        XCTAssertEqual(step.notice, ProxySettingsMigrationNotice(legacyRecordDropped: false))
    }

    func testNoticeSurvivesACodableEntryRoundTrip() throws {
        let notice: ProxySettingsMigrationNotice = ProxySettingsMigrationNotice(legacyRecordDropped: true, dismissed: true)
        let entry: CodableEntry = try XCTUnwrap(CodableEntry(notice))
        XCTAssertEqual(entry.get(ProxySettingsMigrationNotice.self), notice)
    }
}
