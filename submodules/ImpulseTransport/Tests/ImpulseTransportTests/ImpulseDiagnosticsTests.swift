import Foundation
import XCTest
@testable import ImpulseTransport


/// Builds a JWT-shaped identity token with the claims the tag reads. The signature is not checked by the client.
private func diagnosticsToken(
    sub: String,
    origIat: Int64
) -> String {
    let header: String = "{\"alg\":\"none\"}"
    let payload: String = "{\"sub\":\"\(sub)\",\"exp\":2000000000,\"iat\":\(origIat),\"orig_iat\":\(origIat)}"
    return diagnosticsBase64Url(header) + "." + diagnosticsBase64Url(payload) + ".sig"
}


private func diagnosticsBase64Url(_ text: String) -> String {
    return Data(text.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}


/// Keeps the messages a sink receives, in order.
private final class DiagnosticsRecorder: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var messages: [String] = []


    func append(_ message: String) {
        self.lock.lock()
        self.messages.append(message)
        self.lock.unlock()
    }


    func all() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.messages
    }
}


final class ImpulseDiagnosticsTests: XCTestCase {
    func testIdentityTagHoldsEightHexDigitsAndOrigIatButNotTheSubject() throws {
        let subject: String = "i:0123456789abcdef0123456789abcdef"
        let token: String = diagnosticsToken(sub: subject, origIat: 1_000_000)

        let tag: String = try XCTUnwrap(ImpulseDiagnostics.identityTag(token: token))
        let parts: [Substring] = tag.split(separator: " ")

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 8)
        XCTAssertTrue(parts[0].allSatisfy { (character: Character) -> Bool in
            return character.isHexDigit
        })
        XCTAssertEqual(parts[1], "orig_iat")
        XCTAssertEqual(parts[2], "1000000")
        XCTAssertFalse(tag.contains("0123456789abcdef"))
        XCTAssertFalse(tag.contains(token))
    }


    func testIdentityTagIsTheSameForTheSameSubjectAndDiffersForAnother() throws {
        let first: String = try XCTUnwrap(ImpulseDiagnostics.identityTag(token: diagnosticsToken(sub: "i:aaaa", origIat: 5)))
        let again: String = try XCTUnwrap(ImpulseDiagnostics.identityTag(token: diagnosticsToken(sub: "i:aaaa", origIat: 5)))
        let other: String = try XCTUnwrap(ImpulseDiagnostics.identityTag(token: diagnosticsToken(sub: "i:bbbb", origIat: 5)))

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
    }


    func testIdentityTagIsNilWithoutAReadableToken() {
        XCTAssertNil(ImpulseDiagnostics.identityTag(token: nil))
        XCTAssertNil(ImpulseDiagnostics.identityTag(token: "not-a-token"))
    }


    func testSinkReceivesTheMessagesUntilItIsRemoved() {
        let recorder: DiagnosticsRecorder = DiagnosticsRecorder()
        ImpulseDiagnostics.setSink({ (message: String) -> Void in
            recorder.append(message)
        })
        ImpulseDiagnostics.log("first")
        ImpulseDiagnostics.setSink(nil)
        ImpulseDiagnostics.log("second")

        XCTAssertEqual(recorder.all(), ["first"])
    }
}
