import Foundation
import XCTest
@testable import ImpulseTransport

final class ImpulseEnvelopeTests: XCTestCase {

    private func bytes(_ text: String) -> Data {
        return Data(text.utf8)
    }


    private func helloBody() -> Data {
        return Data("hello".utf8)
    }


    func testNumberedFrameReadsAllFields() {
        let result: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"pts\":42,\"ptsCount\":2,\"date\":1700000000,\"data\":\"aGVsbG8=\"}")
        )
        let expected: ImpulseEnvelope = ImpulseEnvelope(
            type: 1,
            pts: 42,
            ptsCount: 2,
            date: 1700000000,
            body: helloBody()
        )
        XCTAssertEqual(result, .envelope(expected))
    }


    func testPtsLessFrameReadsPtsAsZero() {
        let result: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":7,\"date\":5,\"data\":\"aGVsbG8=\"}")
        )
        XCTAssertEqual(result, .envelope(ImpulseEnvelope(type: 7, pts: 0, ptsCount: 0, date: 5, body: helloBody())))
    }


    func testNumericStringsAreAcceptedForNumericFields() {
        let result: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":\"1\",\"pts\":\"9\",\"ptsCount\":\"1\",\"date\":\"5\",\"data\":\"aGVsbG8=\"}")
        )
        XCTAssertEqual(result, .envelope(ImpulseEnvelope(type: 1, pts: 9, ptsCount: 1, date: 5, body: helloBody())))
    }


    func testFramesBreakingTheContractAreUndecodable() {
        let frames: [String] = [
            "{\"type\":0,\"pts\":900,\"date\":5,\"data\":\"aGVsbG8=\"}",
            "{\"type\":-3,\"date\":5,\"data\":\"aGVsbG8=\"}",
            "{\"type\":1,\"date\":5,\"data\":\"\"}",
            "{\"pts\":1,\"date\":5,\"data\":\"aGVsbG8=\"}",
            "{\"type\":1,\"pts\":1,\"data\":\"aGVsbG8=\"}",
            "{\"type\":1,\"date\":0,\"data\":\"aGVsbG8=\"}",
            "{\"type\":1,\"date\":5}",
            "{\"type\":1,\"date\":5,\"data\":7}",
            "{\"type\":1,\"date\":5,\"data\":null}",
            "{\"type\":1,\"date\":5,\"data\":[\"aGVsbG8=\"]}",
        ]
        for frame: String in frames {
            XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes(frame)), .undecodable, frame)
        }
    }


    func testInvalidBase64IsUndecodable() {
        let result: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"pts\":1,\"date\":5,\"data\":\"!!!not base64!!!\"}")
        )
        XCTAssertEqual(result, .undecodable)
    }


    func testBase64AcceptsUrlSafeAlphabetWhitespaceAndMissingPadding() {
        let unpadded: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"date\":5,\"data\":\"aGVsbG8\"}")
        )
        XCTAssertEqual(unpadded, .envelope(ImpulseEnvelope(type: 1, pts: 0, ptsCount: 0, date: 5, body: helloBody())))

        let spaced: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"date\":5,\"data\":\"aGVs\\nbG8=\"}")
        )
        XCTAssertEqual(spaced, .envelope(ImpulseEnvelope(type: 1, pts: 0, ptsCount: 0, date: 5, body: helloBody())))

        let urlSafe: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"date\":5,\"data\":\"-_8\"}")
        )
        XCTAssertEqual(urlSafe, .envelope(ImpulseEnvelope(type: 1, pts: 0, ptsCount: 0, date: 5, body: Data([0xfb, 0xff]))))
    }


    func testInvalidNumericFieldsAreUndecodable() {
        let nonNumeric: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"pts\":\"zzz\",\"date\":5,\"data\":\"aGVsbG8=\"}")
        )
        XCTAssertEqual(nonNumeric, .undecodable)

        let boolean: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":true,\"date\":5,\"data\":\"aGVsbG8=\"}")
        )
        XCTAssertEqual(boolean, .undecodable)

        let fractional: ImpulseEnvelopeParseResult = ImpulseEnvelope.parse(
            bytes: bytes("{\"type\":1,\"pts\":1.5,\"date\":5,\"data\":\"aGVsbG8=\"}")
        )
        XCTAssertEqual(fractional, .undecodable)
    }


    func testNonObjectRootIsUndecodable() {
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes("\"text\"")), .undecodable)
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes("null")), .undecodable)
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes("42")), .undecodable)
    }


    func testGarbageBytesAreUndecodableAndNeverCrash() {
        let garbage: [Data?] = [
            nil,
            Data(),
            bytes("not json"),
            bytes("{\"pts\":"),
            Data([0xff, 0xfe, 0x00]),
        ]
        for candidate: Data? in garbage {
            XCTAssertEqual(ImpulseEnvelope.parse(bytes: candidate), .undecodable)
        }
    }


    func testLegacySessionRevokedArrayIsRecognised() {
        let legacy: String = "[{\"event_type\":\"session.revoked\",\"reason\":\"banned\",\"api_id\":3,\"session_hash\":\"abc\"}]"
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes(legacy)), .legacySessionRevoked)
    }


    func testArraysThatAreNotSessionRevokedAreUndecodable() {
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes("[]")), .undecodable)
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: bytes("[1,2]")), .undecodable)
        XCTAssertEqual(
            ImpulseEnvelope.parse(bytes: bytes("[{\"event_type\":\"other\"}]")),
            .undecodable
        )
        XCTAssertEqual(
            ImpulseEnvelope.parse(bytes: bytes("[{\"event_type\":\"session.revoked\"},{\"x\":1}]")),
            .undecodable
        )
    }


    func testPtsLessFactoryRoundTrips() throws {
        let original: ImpulseEnvelope = ImpulseEnvelope.ptsLess(type: 805, date: 1700000001, body: helloBody())
        let encoded: Data = try original.jsonData()
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: encoded), .envelope(original))
    }


    func testNumberedFactoryRoundTrips() throws {
        let original: ImpulseEnvelope = ImpulseEnvelope.numbered(
            type: 2,
            pts: 1_000_000_000_000,
            ptsCount: 3,
            date: 1700000002,
            body: helloBody()
        )
        let encoded: Data = try original.jsonData()
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: encoded), .envelope(original))
    }


    func testUnnumberedFactoryReadsPtsAsZero() throws {
        let original: ImpulseEnvelope = ImpulseEnvelope.unnumbered(type: 9, date: 1700000003, body: helloBody())
        XCTAssertEqual(original.pts, 0)
        XCTAssertEqual(original.ptsCount, 0)
        let encoded: Data = try original.jsonData()
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: encoded), .envelope(original))
    }


    func testUpdatesTooLongFactoryIsUnnumbered() throws {
        let original: ImpulseEnvelope = ImpulseEnvelope.updatesTooLong(type: 9, date: 1700000004, body: helloBody())
        XCTAssertEqual(original.pts, 0)
        XCTAssertEqual(original.ptsCount, 0)
        let encoded: Data = try original.jsonData()
        XCTAssertEqual(ImpulseEnvelope.parse(bytes: encoded), .envelope(original))
    }
}
