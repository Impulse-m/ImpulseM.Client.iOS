import XCTest
@testable import ImpulseTransport


final class ImpulseDeclarationTests: XCTestCase {
    private struct DecodedDeclaration {
        var varints: [Int: UInt64] = [:]
        var strings: [Int: String] = [:]
    }


    func testInitConnectionFieldsOneToSevenAreWritten() throws {
        let declaration: ImpulseDeclaration = sampleDeclaration()
        let decoded: DecodedDeclaration = try decode(declaration.initConnectionRequest())
        XCTAssertEqual(decoded.varints[1], 9)
        XCTAssertEqual(decoded.strings[2], "MacBook Pro")
        XCTAssertEqual(decoded.strings[3], "macOS 15.4")
        XCTAssertEqual(decoded.strings[4], "12.4")
        XCTAssertEqual(decoded.strings[5], "en")
        XCTAssertEqual(decoded.strings[6], "macos")
        XCTAssertEqual(decoded.strings[7], "en")
        XCTAssertEqual(decoded.varints.count, 1)
        XCTAssertEqual(decoded.strings.count, 6)
    }


    func testProxyAndParamsFieldsAreSkipped() throws {
        let decoded: DecodedDeclaration = try decode(sampleDeclaration().initConnectionRequest())
        XCTAssertNil(decoded.varints[8])
        XCTAssertNil(decoded.strings[8])
        XCTAssertNil(decoded.varints[9])
        XCTAssertNil(decoded.strings[9])
    }


    func testEmptyValuesAndZeroApiIdAreOmitted() throws {
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: 0,
            deviceModel: "MacBook Pro",
            systemVersion: "",
            appVersion: "12.4",
            systemLangCode: "en",
            langPack: "macos",
            langCode: ""
        )
        let decoded: DecodedDeclaration = try decode(declaration.initConnectionRequest())
        XCTAssertNil(decoded.varints[1])
        XCTAssertNil(decoded.strings[3])
        XCTAssertNil(decoded.strings[7])
        XCTAssertEqual(decoded.strings[2], "MacBook Pro")
    }


    func testLangPackIsMacos() throws {
        XCTAssertEqual(ImpulseDeclaration.macosLangPack, "macos")
        XCTAssertEqual(ImpulseDeclaration.initConnectionMethod, "initConnection")
        let decoded: DecodedDeclaration = try decode(sampleDeclaration().initConnectionRequest())
        XCTAssertEqual(decoded.strings[6], "macos")
    }


    func testLimitsTruncateEachField() throws {
        let long: String = String(repeating: "x", count: 200)
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: 9,
            deviceModel: long,
            systemVersion: long,
            appVersion: long,
            systemLangCode: long,
            langPack: long,
            langCode: long
        )
        XCTAssertEqual(declaration.deviceModel.utf16.count, 100)
        XCTAssertEqual(declaration.systemVersion.utf16.count, 50)
        XCTAssertEqual(declaration.appVersion.utf16.count, 50)
        XCTAssertEqual(declaration.systemLangCode.utf16.count, 32)
        XCTAssertEqual(declaration.langPack.utf16.count, 50)
        XCTAssertEqual(declaration.langCode.utf16.count, 64)
    }


    func testTruncationKeepsWholeGraphemeClusters() {
        let family: String = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let deviceModel: String = String(repeating: "a", count: 99) + family
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: 9,
            deviceModel: deviceModel,
            systemVersion: "15",
            appVersion: "12",
            systemLangCode: "en",
            langPack: "macos",
            langCode: "en"
        )
        XCTAssertEqual(declaration.deviceModel, String(repeating: "a", count: 99))
    }


    func testTruncationAtExactLimitKeepsValue() {
        let exact: String = String(repeating: "b", count: 32)
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: 9,
            deviceModel: "MacBook Pro",
            systemVersion: "15",
            appVersion: "12",
            systemLangCode: exact,
            langPack: "macos",
            langCode: "en"
        )
        XCTAssertEqual(declaration.systemLangCode, exact)
    }


    func testTruncatedValueIsWrittenOnTheWire() throws {
        let long: String = String(repeating: "c", count: 300)
        let declaration: ImpulseDeclaration = ImpulseDeclaration(
            apiId: 9,
            deviceModel: long,
            systemVersion: "15",
            appVersion: "12",
            systemLangCode: "en",
            langPack: "macos",
            langCode: "en"
        )
        let decoded: DecodedDeclaration = try decode(declaration.initConnectionRequest())
        XCTAssertEqual(decoded.strings[2], String(repeating: "c", count: 100))
    }


    func testWithLangCodeChangesOnlyLanguage() {
        let declaration: ImpulseDeclaration = sampleDeclaration()
        let switched: ImpulseDeclaration = declaration.withLangCode("ru")
        XCTAssertEqual(switched.langCode, "ru")
        XCTAssertEqual(switched.systemLangCode, "en")
        XCTAssertEqual(switched.deviceModel, declaration.deviceModel)
        XCTAssertNotEqual(switched, declaration)
    }


    func testWithSystemLangCodeChangesOnlySystemLanguage() {
        let declaration: ImpulseDeclaration = sampleDeclaration()
        let switched: ImpulseDeclaration = declaration.withSystemLangCode("de")
        XCTAssertEqual(switched.systemLangCode, "de")
        XCTAssertEqual(switched.langCode, "en")
        XCTAssertNotEqual(switched, declaration)
    }


    func testDeclarerKeyEqualityFollowsCredentialAndDeclaration() {
        let declaration: ImpulseDeclaration = sampleDeclaration()
        let key: ImpulseDeclarationKey = ImpulseDeclarationKey(credential: "token-a", declaration: declaration)
        XCTAssertEqual(
            key,
            ImpulseDeclarationKey(credential: "token-a", declaration: sampleDeclaration())
        )
        XCTAssertNotEqual(
            key,
            ImpulseDeclarationKey(credential: "token-b", declaration: declaration)
        )
        XCTAssertNotEqual(
            key,
            ImpulseDeclarationKey(credential: "token-a", declaration: declaration.withLangCode("fr"))
        )
    }


    private func sampleDeclaration() -> ImpulseDeclaration {
        return ImpulseDeclaration(
            apiId: 9,
            deviceModel: "MacBook Pro",
            systemVersion: "macOS 15.4",
            appVersion: "12.4",
            systemLangCode: "en",
            langPack: ImpulseDeclaration.macosLangPack,
            langCode: "en"
        )
    }


    private func decode(_ data: [UInt8]) throws -> DecodedDeclaration {
        var outer: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        var declarationBytes: [UInt8] = []
        while try outer.next() {
            if outer.field == 1 && outer.wireType == 2 {
                declarationBytes = try outer.readBytes()
            }
        }
        var result: DecodedDeclaration = DecodedDeclaration()
        var reader: ImpulseProtoReader = try ImpulseProtoReader(
            data: declarationBytes,
            offset: 0,
            length: declarationBytes.count
        )
        while try reader.next() {
            if reader.wireType == 0 {
                result.varints[reader.field] = try reader.readVarint()
            } else if reader.wireType == 2 {
                let bytes: [UInt8] = try reader.readBytes()
                result.strings[reader.field] = String(decoding: bytes, as: UTF8.self)
            }
        }
        return result
    }
}
