import XCTest
@testable import TelegramCore

final class ChatFoldersInviteSlugTests: XCTestCase {
    func testStripsUpstreamPrefix() {
        XCTAssertEqual(chatFolderInviteSlug(link: "https://t.me/addlist/abc123"), "abc123")
    }

    func testStripsImpulseMPublicPrefix() {
        XCTAssertEqual(chatFolderInviteSlug(link: "https://o.example.org/addlist/abc123"), "abc123")
    }

    func testStripsAnyPublicPrefixEndingInSlash() {
        XCTAssertEqual(chatFolderInviteSlug(link: "https://example.test/base/addlist/abc123"), "abc123")
    }

    func testStripsMarkerWithoutPrefix() {
        XCTAssertEqual(chatFolderInviteSlug(link: "addlist/abc123"), "abc123")
    }

    func testBareSlugIsKept() {
        XCTAssertEqual(chatFolderInviteSlug(link: "abc123"), "abc123")
    }

    func testMarkerInsideAnotherWordIsNotStripped() {
        XCTAssertEqual(chatFolderInviteSlug(link: "https://t.me/notaddlist/abc123"), "https://t.me/notaddlist/abc123")
    }

    func testExportedLinkSlugUsesThePublicPrefixRule() {
        let link: ExportedChatFolderLink = ExportedChatFolderLink(
            title: "Work",
            link: "https://o.example.org/addlist/xyz789",
            peerIds: [],
            isRevoked: false
        )
        XCTAssertEqual(link.slug, "xyz789")
    }
}
