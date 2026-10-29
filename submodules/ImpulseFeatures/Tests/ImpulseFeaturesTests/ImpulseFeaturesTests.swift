import XCTest
@testable import ImpulseFeatures


final class ImpulseFeaturesTests: XCTestCase {
    func testHideFlagsDefaultToFalse() {
        XCTAssertFalse(ImpulseFeatures.STORIES_POSTING)
        XCTAssertFalse(ImpulseFeatures.BOOSTS)
        XCTAssertFalse(ImpulseFeatures.STARS_AND_TON)
        XCTAssertFalse(ImpulseFeatures.SECRET_CHATS)
        XCTAssertFalse(ImpulseFeatures.AI_COMPOSE)
        XCTAssertFalse(ImpulseFeatures.CHAT_WALLPAPER_AND_THEME)
        XCTAssertFalse(ImpulseFeatures.BROWSER_SETTINGS)
        XCTAssertFalse(ImpulseFeatures.COMMUNITIES)
        XCTAssertFalse(ImpulseFeatures.PAYMENT_SHIPPING_INFO)
        XCTAssertFalse(ImpulseFeatures.PROXY)
        XCTAssertFalse(ImpulseFeatures.HELP_SECTION)
        XCTAssertFalse(ImpulseFeatures.CALL_VERIFICATION)
        XCTAssertFalse(ImpulseFeatures.TEST_BACKEND)
    }


    func testVlessDefaultsToTrue() {
        XCTAssertTrue(ImpulseFeatures.VLESS)
    }
}
