import XCTest
@testable import ImpulseTransport

final class ImpulseTranscoderTests: XCTestCase {
    private func loadMapping() throws -> ImpulseMapping {
        return try ImpulseMapping.loadBundled()
    }


    private func bytes(hex: String) throws -> [UInt8] {
        let compact: String = hex.filter { (character: Character) -> Bool in
            return !character.isWhitespace
        }
        var result: [UInt8] = []
        var index: String.Index = compact.startIndex
        while index < compact.endIndex {
            let next: String.Index = compact.index(index, offsetBy: 2)
            let value: UInt8 = try XCTUnwrap(UInt8(compact[index..<next], radix: 16))
            result.append(value)
            index = next
        }
        return result
    }


    private func idOfMethod(mapping: ImpulseMapping, name: String) throws -> UInt32 {
        let method: ImpulseMappingMethod = try XCTUnwrap(mapping.method(name: name))
        return method.id
    }


    /// The little-endian hex of a 32-bit id, as it appears on the TL wire.
    private func littleEndianHex(_ value: UInt32) -> String {
        var result: String = ""
        for index: Int in 0..<4 {
            let byte: UInt32 = (value >> UInt32(8 * index)) & 0xFF
            let text: String = String(byte, radix: 16)
            result += byte < 16 ? "0" + text : text
        }
        return result
    }


    private func assertEncodeFailed(
        _ expression: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("expected encodeFailed", file: file, line: line)
        } catch let error as ImpulseTranscodeError {
            guard case .encodeFailed = error else {
                XCTFail("expected encodeFailed, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }


    private func assertDecodeFailed(
        _ expression: () throws -> Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try expression()
            XCTFail("expected decodeFailed", file: file, line: line)
        } catch let error as ImpulseTranscodeError {
            guard case .decodeFailed = error else {
                XCTFail("expected decodeFailed, got \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }


    // MARK: Golden vectors


    func testGoldenMessageToProtoAndBack() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(
            hex: "d3b90076 02000001 02000000 2a000000 22175159 0500000000000000 00f15365 02686900"
        )
        let proto: [UInt8] = try bytes(
            hex: "121c 0801 4801 6001 80012a a20104 0a020805 d00180e2cfaa06 da01026869"
        )

        XCTAssertEqual(try transcoder.tlObjectToProto(typeName: "Message", tl: tl), proto)
        XCTAssertEqual(try transcoder.protoToTlObject(typeName: "Message", proto: proto, capture: nil), tl)
    }


    func testGoldenPeerUserToProtoAndBack() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(hex: "22175159 0500000000000000")
        let proto: [UInt8] = try bytes(hex: "0a020805")

        XCTAssertEqual(try transcoder.tlObjectToProto(typeName: "Peer", tl: tl), proto)
        XCTAssertEqual(try transcoder.protoToTlObject(typeName: "Peer", proto: proto, capture: nil), tl)
    }


    func testGoldenUsersGetUsersResultIsVector() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let usersMethodId: UInt32 = try idOfMethod(mapping: mapping, name: "users.getUsers")
        let proto: [UInt8] = try bytes(hex: "0a040a02080b0a040a02080b")
        let expected: [UInt8] = try bytes(
            hex: "15c4b51c 02000000 7a4bbcd3 0b00000000000000 7a4bbcd3 0b00000000000000"
        )

        let decoded: [UInt8] = try transcoder.decodeResult(methodId: usersMethodId, proto: proto, capture: nil)
        XCTAssertEqual(decoded, expected)
    }


    func testGoldenAuthorizationCapturesTokens() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let proto: [UInt8] = try bytes(hex: "0a0c 2a040a020803 320141 3a0142")
        let expected: [UInt8] = try bytes(hex: "d4c0a22e 00000000 7a4bbcd3 0300000000000000")
        var captured: [String] = []

        let decoded: [UInt8] = try transcoder.protoToTlObject(
            typeName: "auth.Authorization",
            proto: proto,
            capture: { (protoMessage: String, fieldName: String, value: String) -> Void in
                captured.append(protoMessage + "." + fieldName + "=" + value)
            }
        )

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(
            captured,
            ["AuthAuthorizationValue.session_token=A", "AuthAuthorizationValue.refresh_token=B"]
        )
    }


    func testGoldenHelpGetConfigWrappedIsUnwrapped() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(
            hex: "0d0d9bda e5000000 a95ecdc1 00000000 03000000 "
                + "02764e00 02764e00 02764e00 02764e00 02764e00 02764e00 6b18f9c4"
        )

        let request: ImpulseEncodedRequest = try transcoder.encodeRequest(tl: tl)
        XCTAssertEqual(request.method, "help.getConfig")
        XCTAssertEqual(request.proto, [])
        XCTAssertNil(request.takeoutId)
    }


    func testWrappedTakeoutIsReportedNotAnswered() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(hex: "2efda9ac 2a00000000000000 6b18f9c4")

        let request: ImpulseEncodedRequest = try transcoder.encodeRequest(tl: tl)
        XCTAssertEqual(request.method, "help.getConfig")
        XCTAssertEqual(request.takeoutId, 42)
    }


    // MARK: Edge cases


    func testPresentZeroScalarIsWritten() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(hex: "22175159 0000000000000000")

        XCTAssertEqual(try transcoder.tlObjectToProto(typeName: "Peer", tl: tl), try bytes(hex: "0a020800"))
    }


    func testZeroLengthSubmessageTakesDefaults() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let proto: [UInt8] = try bytes(hex: "0a00")
        let expected: [UInt8] = try bytes(hex: "22175159 0000000000000000")

        XCTAssertEqual(try transcoder.protoToTlObject(typeName: "Peer", proto: proto, capture: nil), expected)
    }


    func testUnknownProtoFieldIsIgnored() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let proto: [UInt8] = try bytes(hex: "0a04 0805 4801")
        let expected: [UInt8] = try bytes(hex: "22175159 0500000000000000")

        XCTAssertEqual(try transcoder.protoToTlObject(typeName: "Peer", proto: proto, capture: nil), expected)
    }


    func testExplicitFalseFlagIsOmitted() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(
            hex: "d3b90076 00000000 00000000 2a000000 22175159 0500000000000000 00f15365 02686900"
        )
        let proto: [UInt8] = try bytes(
            hex: "12 16 80 01 2a a2 01 04 0a 02 08 05 d0 01 80 e2 cf aa 06 da 01 02 68 69"
        )

        XCTAssertEqual(try transcoder.tlObjectToProto(typeName: "Message", tl: tl), proto)
        XCTAssertEqual(try transcoder.protoToTlObject(typeName: "Message", proto: proto, capture: nil), tl)
    }


    func testPackedVectorEncodesAndUnpackedDecodes() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let deleteId: UInt32 = try idOfMethod(mapping: mapping, name: "messages.deleteMessages")
        let tl: [UInt8] = try bytes(
            hex: littleEndianHex(deleteId) + " 00000000 15c4b51c 02000000 01000000 2c010000"
        )

        let request: ImpulseEncodedRequest = try transcoder.encodeRequest(tl: tl)
        XCTAssertEqual(request.proto, try bytes(hex: "12 03 01 ac 02"))

        let unpacked: [UInt8] = try bytes(hex: "10 01 10 ac 02")
        let decoded: [UInt8] = try transcoder.decodeRequest(methodId: deleteId, proto: unpacked)
        XCTAssertEqual(decoded, tl)
    }


    func testBoolResultValues() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let resetId: UInt32 = try idOfMethod(mapping: mapping, name: "auth.resetAuthorizations")

        let yes: [UInt8] = try transcoder.decodeResult(
            methodId: resetId,
            proto: try bytes(hex: "08 01"),
            capture: nil
        )
        XCTAssertEqual(yes, try bytes(hex: "b5 75 72 99"))
        let no: [UInt8] = try transcoder.decodeResult(
            methodId: resetId,
            proto: try bytes(hex: "08 00"),
            capture: nil
        )
        XCTAssertEqual(no, try bytes(hex: "37 97 79 bc"))
    }


    func testTranscodeErrorsAnswerClientCodes() {
        XCTAssertEqual(ImpulseTranscodeError.methodNotMapped(1).rpcError?.text, "CLIENT_METHOD_NOT_MAPPED")
        XCTAssertEqual(ImpulseTranscodeError.encodeFailed("x").rpcError?.text, "CLIENT_TRANSCODE_FAILED")
        XCTAssertEqual(ImpulseTranscodeError.responseParseFailed("x").rpcError?.text, "CLIENT_RESPONSE_PARSE_FAILED")
        XCTAssertEqual(ImpulseTranscodeError.encodeFailed("x").rpcError?.code, 400)
        XCTAssertNil(ImpulseTranscodeError.decodeFailed("x").rpcError)
    }


    // MARK: Negatives


    func testUnsetOneofThrows() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)

        do {
            _ = try transcoder.protoToTlObject(typeName: "Peer", proto: [], capture: nil)
            XCTFail("an unset oneof must throw")
        } catch let error as ImpulseTranscodeError {
            XCTAssertEqual(error, ImpulseTranscodeError.decodeFailed("unset oneof for Peer"))
        }
    }


    func testBoolResultWithoutValueFails() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let resetId: UInt32 = try idOfMethod(mapping: mapping, name: "auth.resetAuthorizations")

        do {
            _ = try transcoder.decodeResult(methodId: resetId, proto: [], capture: nil)
            XCTFail("an absent Bool value must not decode")
        } catch let error as ImpulseTranscodeError {
            guard case .responseParseFailed = error else {
                XCTFail("expected responseParseFailed, got \(error)")
                return
            }
        }
    }


    func testAbsentRequiredObjectFails() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let proto: [UInt8] = try bytes(hex: "12 0f 80 01 2a d0 01 80 e2 cf aa 06 da 01 02 68 69")

        assertDecodeFailed {
            return try transcoder.protoToTlObject(typeName: "Message", proto: proto, capture: nil)
        }
    }


    func testUnknownMethodThrowsMethodNotMapped() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(hex: "78563412")

        do {
            _ = try transcoder.encodeRequest(tl: tl)
            XCTFail("an unknown method must throw")
        } catch let error as ImpulseTranscodeError {
            XCTAssertEqual(error, ImpulseTranscodeError.methodNotMapped(0x12345678))
        }
    }


    func testUnknownConstructorThrows() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let tl: [UInt8] = try bytes(hex: "78563412")

        assertEncodeFailed {
            return try transcoder.tlObjectToProto(typeName: "Peer", tl: tl)
        }
    }


    func testTruncatedInputThrows() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let peerTruncated: [UInt8] = try bytes(hex: "22175159 0500")
        let requestTruncated: [UInt8] = try bytes(hex: "0d0d9bda e5")

        assertEncodeFailed {
            return try transcoder.tlObjectToProto(typeName: "Peer", tl: peerTruncated)
        }
        assertEncodeFailed {
            return try transcoder.encodeRequest(tl: requestTruncated)
        }
    }


    func testUnmappedParamFails() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let checkId: UInt32 = try idOfMethod(mapping: mapping, name: "bots.checkUsername")
        let tl: [UInt8] = try bytes(hex: littleEndianHex(checkId) + " 01000000 01780000")

        assertEncodeFailed {
            return try transcoder.encodeRequest(tl: tl)
        }
    }


    func testUnmappedConstructorFailsToEncode() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let constructor: ImpulseMappingConstructor = try XCTUnwrap(
            mapping.constructors.first { (candidate: ImpulseMappingConstructor) -> Bool in
                return candidate.predicate == "botVerification"
            }
        )
        let tl: [UInt8] = try bytes(hex: littleEndianHex(constructor.id))

        assertEncodeFailed {
            return try transcoder.tlObjectToProto(typeName: constructor.typeName, tl: tl)
        }
    }
}
