enum ImpulseWireError: Error, Equatable {
    case badBounds
    case truncated
    case malformedVarint
    case lengthOutOfBounds
    case unsupportedWireType(Int)
    case tlBytesTooLong(Int)
    case tlPatchOutOfRange(Int)
}


struct ImpulseProtoWriter {
    private var output: [UInt8] = []


    mutating func writeVarintField(field: Int, value: UInt64) {
        writeTag(field: field, wireType: 0)
        writeVarint(value: value)
    }


    mutating func writeInt32Field(field: Int, value: Int32) {
        let extended: Int64 = Int64(value)
        writeVarintField(field: field, value: UInt64(bitPattern: extended))
    }


    mutating func writeInt64Field(field: Int, value: Int64) {
        writeVarintField(field: field, value: UInt64(bitPattern: value))
    }


    mutating func writeFixed64Field(field: Int, bits: UInt64) {
        writeTag(field: field, wireType: 1)
        writeFixed64(bits: bits)
    }


    mutating func writeBytesField(field: Int, value: [UInt8]) {
        writeTag(field: field, wireType: 2)
        writeVarint(value: UInt64(value.count))
        output.append(contentsOf: value)
    }


    mutating func writePackedVarints(field: Int, values: [UInt64]) {
        var inner: ImpulseProtoWriter = ImpulseProtoWriter()
        for value: UInt64 in values {
            inner.writeVarint(value: value)
        }
        writeBytesField(field: field, value: inner.toByteArray())
    }


    mutating func writePackedFixed64(field: Int, bitsList: [UInt64]) {
        var inner: ImpulseProtoWriter = ImpulseProtoWriter()
        for bits: UInt64 in bitsList {
            inner.writeFixed64(bits: bits)
        }
        writeBytesField(field: field, value: inner.toByteArray())
    }


    func toByteArray() -> [UInt8] {
        return output
    }


    private mutating func writeTag(field: Int, wireType: Int) {
        let tag: UInt64 = (UInt64(field) << 3) | UInt64(wireType)
        writeVarint(value: tag)
    }


    private mutating func writeVarint(value: UInt64) {
        var remaining: UInt64 = value
        while (remaining & ~UInt64(0x7F)) != 0 {
            output.append(UInt8(truncatingIfNeeded: (remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        output.append(UInt8(truncatingIfNeeded: remaining))
    }


    private mutating func writeFixed64(bits: UInt64) {
        for index: Int in 0..<8 {
            output.append(UInt8(truncatingIfNeeded: bits >> (8 * index)))
        }
    }
}


struct ImpulseProtoReader {
    private(set) var field: Int = 0
    private(set) var wireType: Int = 0
    private let data: [UInt8]
    private let end: Int
    private var position: Int
    private var valueConsumed: Bool = true


    var hasMore: Bool {
        return position < end
    }


    init(data: [UInt8], offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ImpulseWireError.badBounds
        }
        self.data = data
        self.position = offset
        self.end = offset + length
    }


    mutating func next() throws -> Bool {
        if !valueConsumed {
            try skip()
        }
        if position >= end {
            return false
        }
        let tag: UInt64 = try rawVarint()
        field = Int(truncatingIfNeeded: tag >> 3)
        wireType = Int(truncatingIfNeeded: tag & 7)
        valueConsumed = false
        return true
    }


    mutating func readVarint() throws -> UInt64 {
        valueConsumed = true
        return try rawVarint()
    }


    mutating func readInt64() throws -> Int64 {
        let raw: UInt64 = try readVarint()
        return Int64(bitPattern: raw)
    }


    mutating func readFixed64() throws -> UInt64 {
        valueConsumed = true
        try require(count: 8)
        var result: UInt64 = 0
        for index: Int in (0..<8).reversed() {
            result = (result << 8) | UInt64(data[position + index])
        }
        position += 8
        return result
    }


    mutating func readFixed32() throws -> UInt32 {
        valueConsumed = true
        try require(count: 4)
        var result: UInt32 = 0
        for index: Int in (0..<4).reversed() {
            result = (result << 8) | UInt32(data[position + index])
        }
        position += 4
        return result
    }


    mutating func readBytes() throws -> [UInt8] {
        let bounds: Range<Int> = try readLengthDelimitedRange()
        return Array(data[bounds])
    }


    mutating func readLengthDelimitedRange() throws -> Range<Int> {
        valueConsumed = true
        let length: UInt64 = try rawVarint()
        let available: Int = end - position
        guard length <= UInt64(available) else {
            throw ImpulseWireError.lengthOutOfBounds
        }
        let start: Int = position
        position += Int(length)
        return start..<position
    }


    mutating func skip() throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            _ = try readFixed64()
        case 2:
            _ = try readLengthDelimitedRange()
        case 5:
            _ = try readFixed32()
        default:
            throw ImpulseWireError.unsupportedWireType(wireType)
        }
        valueConsumed = true
    }


    private mutating func rawVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            try require(count: 1)
            let byte: UInt8 = data[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        throw ImpulseWireError.malformedVarint
    }


    private func require(count: Int) throws {
        if count < 0 || position + count > end {
            throw ImpulseWireError.truncated
        }
    }
}


struct ImpulseTlWriter {
    var position: Int {
        return buffer.count
    }


    private var buffer: [UInt8] = []


    mutating func writeInt32(value: Int32) {
        appendLittleEndian(bits: UInt64(UInt32(bitPattern: value)), byteCount: 4)
    }


    mutating func writeInt64(value: Int64) {
        appendLittleEndian(bits: UInt64(bitPattern: value), byteCount: 8)
    }


    mutating func writeDouble(value: Double) {
        writeInt64(value: Int64(bitPattern: value.bitPattern))
    }


    mutating func writeBytes(value: [UInt8]) throws {
        let length: Int = value.count
        var headerSize: Int = 1
        if length < 254 {
            buffer.append(UInt8(length))
        } else {
            guard length <= 0xFFFFFF else {
                throw ImpulseWireError.tlBytesTooLong(length)
            }
            buffer.append(0xFE)
            appendLittleEndian(bits: UInt64(length), byteCount: 3)
            headerSize = 4
        }
        buffer.append(contentsOf: value)
        let padding: Int = (4 - (headerSize + length) % 4) % 4
        buffer.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }


    mutating func writeString(value: String) throws {
        try writeBytes(value: Array(value.utf8))
    }


    mutating func writeRaw(value: [UInt8]) {
        buffer.append(contentsOf: value)
    }


    mutating func patchInt32(offset: Int, value: Int32) throws {
        guard offset >= 0, offset + 4 <= buffer.count else {
            throw ImpulseWireError.tlPatchOutOfRange(offset)
        }
        let bits: UInt64 = UInt64(UInt32(bitPattern: value))
        for index: Int in 0..<4 {
            buffer[offset + index] = UInt8(truncatingIfNeeded: bits >> (8 * index))
        }
    }


    func toByteArray() -> [UInt8] {
        return buffer
    }


    private mutating func appendLittleEndian(bits: UInt64, byteCount: Int) {
        for index: Int in 0..<byteCount {
            buffer.append(UInt8(truncatingIfNeeded: bits >> (8 * index)))
        }
    }
}


struct ImpulseTlReader {
    var position: Int {
        return cursor - start
    }


    var remaining: Int {
        return end - cursor
    }


    private let data: [UInt8]
    private let start: Int
    private let end: Int
    private var cursor: Int


    init(data: [UInt8], offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ImpulseWireError.badBounds
        }
        self.data = data
        self.start = offset
        self.end = offset + length
        self.cursor = offset
    }


    mutating func readInt32() throws -> Int32 {
        let bits: UInt64 = try readLittleEndian(byteCount: 4)
        return Int32(bitPattern: UInt32(truncatingIfNeeded: bits))
    }


    mutating func readInt64() throws -> Int64 {
        let bits: UInt64 = try readLittleEndian(byteCount: 8)
        return Int64(bitPattern: bits)
    }


    mutating func readDouble() throws -> Double {
        let bits: UInt64 = try readLittleEndian(byteCount: 8)
        return Double(bitPattern: bits)
    }


    mutating func readBytes() throws -> [UInt8] {
        try require(count: 1)
        var length: Int = Int(data[cursor])
        var headerSize: Int = 1
        if length >= 254 {
            try require(count: 4)
            length = Int(data[cursor + 1]) | (Int(data[cursor + 2]) << 8) | (Int(data[cursor + 3]) << 16)
            headerSize = 4
        }
        let padded: Int = ((headerSize + length + 3) / 4) * 4
        try require(count: padded)
        let result: [UInt8] = Array(data[(cursor + headerSize)..<(cursor + headerSize + length)])
        cursor += padded
        return result
    }


    mutating func readString() throws -> String {
        let bytes: [UInt8] = try readBytes()
        return String(decoding: bytes, as: UTF8.self)
    }


    mutating func readRaw(count: Int) throws -> [UInt8] {
        try require(count: count)
        let result: [UInt8] = Array(data[cursor..<(cursor + count)])
        cursor += count
        return result
    }


    private mutating func readLittleEndian(byteCount: Int) throws -> UInt64 {
        try require(count: byteCount)
        var bits: UInt64 = 0
        for index: Int in 0..<byteCount {
            bits |= UInt64(data[cursor + index]) << (8 * index)
        }
        cursor += byteCount
        return bits
    }


    private func require(count: Int) throws {
        if count < 0 || cursor + count > end {
            throw ImpulseWireError.truncated
        }
    }
}
