import XCTest
@testable import ImpulseTransport

final class ImpulseWireTests: XCTestCase {
    private func filled(count: Int, value: UInt8) -> [UInt8] {
        return [UInt8](repeating: value, count: count)
    }


    private func tlEncodedBytes(payload: [UInt8]) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        try writer.writeBytes(value: payload)
        return writer.toByteArray()
    }


    func testProtoVarint300() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeVarintField(field: 1, value: 300)
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x08, 0xAC, 0x02])

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertEqual(reader.field, 1)
        let value: UInt64 = try reader.readVarint()
        XCTAssertEqual(value, 300)
    }


    func testProtoNegativeInt32IsSignExtended() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeInt32Field(field: 1, value: -5)
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x08, 0xFB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        let value: Int64 = try reader.readInt64()
        XCTAssertEqual(value, -5)
    }


    func testProtoBytesField() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeBytesField(field: 2, value: [0x61])
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x12, 0x01, 0x61])

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertEqual(reader.field, 2)
        let bytes: [UInt8] = try reader.readBytes()
        XCTAssertEqual(bytes, [0x61])
    }


    func testProtoFixed64DoubleBits() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeFixed64Field(field: 3, bits: Double(1.5).bitPattern)
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x19, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        let bits: UInt64 = try reader.readFixed64()
        XCTAssertEqual(Double(bitPattern: bits), 1.5)
    }


    func testProtoPackedVarints() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writePackedVarints(field: 4, values: [1, 2, 300])
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x22, 0x04, 0x01, 0x02, 0xAC, 0x02])

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        let bounds: Range<Int> = try reader.readLengthDelimitedRange()
        var inner: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: bounds.lowerBound, length: bounds.count)
        let first: UInt64 = try inner.readVarint()
        let second: UInt64 = try inner.readVarint()
        let third: UInt64 = try inner.readVarint()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(third, 300)
    }


    func testProtoPackedFixed64() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writePackedFixed64(field: 5, bitsList: [Double(1.5).bitPattern])
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0x2A, 0x08, 0, 0, 0, 0, 0, 0, 0xF8, 0x3F])
    }


    func testNextSkipsUnreadValues() throws {
        var writer: ImpulseProtoWriter = ImpulseProtoWriter()
        writer.writeVarintField(field: 1, value: 7)
        writer.writeFixed64Field(field: 2, bits: Double(2.5).bitPattern)
        writer.writeBytesField(field: 3, value: [0x01, 0x02])
        let encoded: [UInt8] = writer.toByteArray()

        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let firstField: Bool = try reader.next()
        XCTAssertTrue(firstField)
        XCTAssertEqual(reader.field, 1)
        let secondField: Bool = try reader.next()
        XCTAssertTrue(secondField)
        XCTAssertEqual(reader.field, 2)
        let thirdField: Bool = try reader.next()
        XCTAssertTrue(thirdField)
        XCTAssertEqual(reader.field, 3)
        let bytes: [UInt8] = try reader.readBytes()
        XCTAssertEqual(bytes, [0x01, 0x02])
        let end: Bool = try reader.next()
        XCTAssertFalse(end)
        XCTAssertFalse(reader.hasMore)
    }


    func testProtoSkipsFixed32Field() throws {
        let encoded: [UInt8] = [(2 << 3) | 5, 0x01, 0x00, 0x00, 0x00, (3 << 3) | 0, 0x09]
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: encoded, offset: 0, length: encoded.count)
        let firstField: Bool = try reader.next()
        XCTAssertTrue(firstField)
        XCTAssertEqual(reader.field, 2)
        let secondField: Bool = try reader.next()
        XCTAssertTrue(secondField)
        XCTAssertEqual(reader.field, 3)
        let value: Int64 = try reader.readInt64()
        XCTAssertEqual(value, 9)
    }


    func testProtoBadBoundsRejected() {
        XCTAssertThrowsError(try ImpulseProtoReader(data: [1], offset: 0, length: 2)) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .badBounds)
        }
    }


    func testTlBytesSmall() throws {
        let encoded: [UInt8] = try tlEncodedBytes(payload: [1, 2, 3])
        XCTAssertEqual(encoded, [0x03, 0x01, 0x02, 0x03])

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: [UInt8] = try reader.readBytes()
        XCTAssertEqual(decoded, [1, 2, 3])
        XCTAssertEqual(reader.remaining, 0)
    }


    func testTlBytesEmpty() throws {
        let encoded: [UInt8] = try tlEncodedBytes(payload: [])
        XCTAssertEqual(encoded, [0x00, 0x00, 0x00, 0x00])

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: [UInt8] = try reader.readBytes()
        XCTAssertEqual(decoded.count, 0)
    }


    func testTlBytes253() throws {
        let payload: [UInt8] = filled(count: 253, value: 0x11)
        let encoded: [UInt8] = try tlEncodedBytes(payload: payload)
        XCTAssertEqual(encoded.count, 256)
        XCTAssertEqual(encoded[0], 0xFD)
        XCTAssertEqual(Array(encoded[1...253]), payload)
        XCTAssertEqual(encoded[254], 0)
        XCTAssertEqual(encoded[255], 0)

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: [UInt8] = try reader.readBytes()
        XCTAssertEqual(decoded, payload)
    }


    func testTlBytes254UsesLongHeader() throws {
        let payload: [UInt8] = filled(count: 254, value: 0x22)
        let encoded: [UInt8] = try tlEncodedBytes(payload: payload)
        XCTAssertEqual(encoded.count, 260)
        XCTAssertEqual(Array(encoded[0..<4]), [0xFE, 0xFE, 0x00, 0x00])
        XCTAssertEqual(Array(encoded[4..<258]), payload)
        XCTAssertEqual(encoded[258], 0)
        XCTAssertEqual(encoded[259], 0)

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: [UInt8] = try reader.readBytes()
        XCTAssertEqual(decoded, payload)
    }


    func testTlScalars() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: 0x01020304)
        XCTAssertEqual(writer.toByteArray(), [0x04, 0x03, 0x02, 0x01])

        writer = ImpulseTlWriter()
        writer.writeInt64(value: 1)
        XCTAssertEqual(writer.toByteArray(), [1, 0, 0, 0, 0, 0, 0, 0])

        writer = ImpulseTlWriter()
        writer.writeDouble(value: 1.5)
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0, 0, 0, 0, 0, 0, 0xF8, 0x3F])

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: 8)
        let decodedDouble: Double = try reader.readDouble()
        XCTAssertEqual(decodedDouble, 1.5)

        var int64Reader: ImpulseTlReader = try ImpulseTlReader(data: [1, 0, 0, 0, 0, 0, 0, 0], offset: 0, length: 8)
        let decodedLong: Int64 = try int64Reader.readInt64()
        XCTAssertEqual(decodedLong, 1)

        var int32Reader: ImpulseTlReader = try ImpulseTlReader(data: [4, 3, 2, 1], offset: 0, length: 4)
        let decodedInt: Int32 = try int32Reader.readInt32()
        XCTAssertEqual(decodedInt, 0x01020304)
    }


    func testTlNegativeInt32RoundTrip() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: -5)
        let encoded: [UInt8] = writer.toByteArray()
        XCTAssertEqual(encoded, [0xFB, 0xFF, 0xFF, 0xFF])

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: Int32 = try reader.readInt32()
        XCTAssertEqual(decoded, -5)
    }


    func testTlStringRoundTrip() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        try writer.writeString(value: "héllo")
        let encoded: [UInt8] = writer.toByteArray()

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: String = try reader.readString()
        XCTAssertEqual(decoded, "héllo")
    }


    func testTlRawRoundTrip() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeRaw(value: filled(count: 16, value: 0x11))
        let encoded: [UInt8] = writer.toByteArray()

        var reader: ImpulseTlReader = try ImpulseTlReader(data: encoded, offset: 0, length: encoded.count)
        let decoded: [UInt8] = try reader.readRaw(count: 16)
        XCTAssertEqual(decoded, filled(count: 16, value: 0x11))
    }


    func testTlPatchInt32() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: 0)
        writer.writeInt32(value: 0)
        try writer.patchInt32(offset: 4, value: 0x01020304)
        XCTAssertEqual(writer.toByteArray(), [0, 0, 0, 0, 0x04, 0x03, 0x02, 0x01])
    }


    func testTlBytesTooLongRejected() {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        let oversized: [UInt8] = [UInt8](repeating: 0, count: 0x1000000)
        XCTAssertThrowsError(try writer.writeBytes(value: oversized)) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .tlBytesTooLong(0x1000000))
        }
    }


    func testProtoVarintWithElevenContinuationBytesIsMalformed() throws {
        var data: [UInt8] = [UInt8](repeating: 0x80, count: 12)
        data[0] = 0x08
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertThrowsError(try reader.readVarint()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .malformedVarint)
        }
    }


    func testProtoLengthLargerThanRemainingIsRejected() throws {
        let data: [UInt8] = [0x12, 0x05, 1, 2]
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertThrowsError(try reader.readBytes()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .lengthOutOfBounds)
        }
    }


    func testProtoWireType3IsRejected() throws {
        let data: [UInt8] = [UInt8((1 << 3) | 3)]
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertThrowsError(try reader.skip()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .unsupportedWireType(3))
        }
    }


    func testProtoWireType4IsRejected() throws {
        let data: [UInt8] = [UInt8((1 << 3) | 4)]
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertThrowsError(try reader.skip()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .unsupportedWireType(4))
        }
    }


    func testProtoTruncatedFixed64IsRejected() throws {
        let data: [UInt8] = [UInt8((1 << 3) | 1), 1, 2, 3]
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: 0, length: data.count)
        let hasField: Bool = try reader.next()
        XCTAssertTrue(hasField)
        XCTAssertThrowsError(try reader.readFixed64()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlTruncatedBytesPayloadIsRejected() throws {
        let data: [UInt8] = [0x05, 1, 2]
        var reader: ImpulseTlReader = try ImpulseTlReader(data: data, offset: 0, length: data.count)
        XCTAssertThrowsError(try reader.readBytes()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlTruncatedLongHeaderIsRejected() throws {
        let data: [UInt8] = [0xFE, 0x00]
        var reader: ImpulseTlReader = try ImpulseTlReader(data: data, offset: 0, length: data.count)
        XCTAssertThrowsError(try reader.readBytes()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlTruncatedLongPayloadIsRejected() throws {
        let data: [UInt8] = [0xFE, 0xFF, 0x00, 0x00, 1, 2, 3, 4]
        var reader: ImpulseTlReader = try ImpulseTlReader(data: data, offset: 0, length: data.count)
        XCTAssertThrowsError(try reader.readBytes()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlInt64WithSevenBytesIsRejected() throws {
        let data: [UInt8] = [UInt8](repeating: 0, count: 7)
        var reader: ImpulseTlReader = try ImpulseTlReader(data: data, offset: 0, length: data.count)
        XCTAssertThrowsError(try reader.readInt64()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlInt32WithThreeBytesIsRejected() throws {
        let data: [UInt8] = [0, 0, 0]
        var reader: ImpulseTlReader = try ImpulseTlReader(data: data, offset: 0, length: data.count)
        XCTAssertThrowsError(try reader.readInt32()) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .truncated)
        }
    }


    func testTlPatchOutOfRangeIsRejected() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: 0)
        XCTAssertThrowsError(try writer.patchInt32(offset: 2, value: 1)) { (error: Error) in
            XCTAssertEqual(error as? ImpulseWireError, .tlPatchOutOfRange(2))
        }
    }
}
