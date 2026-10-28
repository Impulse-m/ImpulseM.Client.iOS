/// The reason a transcode failed. Each case answers one local `400 CLIENT_*` error, or none for updates.
public enum ImpulseTranscodeError: Error, Equatable, Sendable {
    /// The method id is absent from the mapping.
    case methodNotMapped(UInt32)
    /// A TL object or request could not be converted to protobuf.
    case encodeFailed(String)
    /// A protobuf object (an update) could not be converted to TL.
    case decodeFailed(String)
    /// A reply could not be converted to TL.
    case responseParseFailed(String)


    /// The human-readable cause of the failure.
    public var reason: String {
        switch self {
        case .methodNotMapped(let id):
            return "method " + String(id, radix: 16) + " is not mapped"
        case .encodeFailed(let text), .decodeFailed(let text), .responseParseFailed(let text):
            return text
        }
    }


    /// The local RPC error this failure answers. Nil for an update that cannot be decoded: the realtime layer
    /// runs a difference for it and never answers an RPC error.
    public var rpcError: ImpulseRpcError? {
        switch self {
        case .methodNotMapped:
            return ImpulseRpcError(code: 400, text: "CLIENT_METHOD_NOT_MAPPED", temporary: false)
        case .encodeFailed:
            return ImpulseRpcError(code: 400, text: "CLIENT_TRANSCODE_FAILED", temporary: false)
        case .responseParseFailed:
            return ImpulseRpcError(code: 400, text: "CLIENT_RESPONSE_PARSE_FAILED", temporary: false)
        case .decodeFailed:
            return nil
        }
    }
}


/// A request ready for a carrier: the protobuf body of its mapped method and the wrapper data it carried.
public struct ImpulseEncodedRequest: Equatable, Sendable {
    /// The method id of the layer 232 mapping.
    public let methodId: UInt32
    /// The canonical TL method name, such as `messages.sendMessage`. It is the carrier registry key.
    public let method: String
    /// The gRPC-style path of the method. It is produced for reference and never sent.
    public let path: String
    /// The protobuf body of the method call.
    public let proto: [UInt8]
    /// The takeout id of an `invokeWithTakeout` wrapper, or nil. The server receives the wrapper.
    public let takeoutId: Int64?


    public init(
        methodId: UInt32,
        method: String,
        path: String,
        proto: [UInt8],
        takeoutId: Int64?
    ) {
        self.methodId = methodId
        self.method = method
        self.path = path
        self.proto = proto
        self.takeoutId = takeoutId
    }
}


/// Receives a captured field of a reply: the proto message name, the field name and the value.
public typealias ImpulseCaptureHandler = (String, String, String) -> Void


/// Converts TL binary to ImpulseM protobuf and back, driven by the layer 232 mapping.
/// The transcoder keeps no state after init, so one instance serves every carrier.
public final class ImpulseTranscoder: Sendable {
    private static let maxDepth: Int = 256


    private let mapping: ImpulseMapping
    private let constructorsByType: [String: [ImpulseMappingConstructor]]


    public convenience init() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        self.init(mapping: mapping)
    }


    public init(mapping: ImpulseMapping) {
        var grouped: [String: [ImpulseMappingConstructor]] = [:]
        for constructor: ImpulseMappingConstructor in mapping.constructors {
            grouped[constructor.typeName, default: []].append(constructor)
        }
        self.mapping = mapping
        self.constructorsByType = grouped
    }


    /// Encodes a bare TL request, with any wrappers around it, into the protobuf body of its method.
    public func encodeRequest(tl: [UInt8]) throws -> ImpulseEncodedRequest {
        do {
            return try encodeRequestUnchecked(tl: tl)
        } catch {
            throw normalize(error, as: ImpulseTranscodeError.encodeFailed)
        }
    }


    /// Decodes a reply of a method into TL. An absent or unknown result fails with `responseParseFailed`.
    public func decodeResult(
        methodId: UInt32,
        proto: [UInt8],
        capture: ImpulseCaptureHandler?
    ) throws -> [UInt8] {
        guard let method: ImpulseMappingMethod = mapping.method(id: methodId) else {
            throw ImpulseTranscodeError.methodNotMapped(methodId)
        }
        do {
            return try decodeResultSpec(result: method.result, proto: proto, captureHandler: capture)
        } catch {
            throw normalize(error, as: ImpulseTranscodeError.responseParseFailed)
        }
    }


    /// Encodes one TL object of the named type into protobuf.
    public func tlObjectToProto(typeName: String, tl: [UInt8]) throws -> [UInt8] {
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            let result: [UInt8] = try objectToProto(typeName: typeName, reader: &reader, depth: 0)
            try requireConsumed(reader: reader)
            return result
        } catch {
            throw normalize(error, as: ImpulseTranscodeError.encodeFailed)
        }
    }


    /// Decodes one protobuf object of the named type into TL. Used for updates.
    public func protoToTlObject(
        typeName: String,
        proto: [UInt8],
        capture: ImpulseCaptureHandler?
    ) throws -> [UInt8] {
        do {
            var writer: ImpulseTlWriter = ImpulseTlWriter()
            try protoToObject(
                typeName: typeName,
                data: proto,
                offset: 0,
                length: proto.count,
                writer: &writer,
                captureHandler: capture,
                depth: 0
            )
            return writer.toByteArray()
        } catch {
            throw normalize(error, as: ImpulseTranscodeError.decodeFailed)
        }
    }


    /// Decodes a request body back to bare TL, for the round-trip checks.
    func decodeRequest(methodId: UInt32, proto: [UInt8]) throws -> [UInt8] {
        do {
            guard let method: ImpulseMappingMethod = mapping.method(id: methodId) else {
                throw ImpulseTranscodeError.methodNotMapped(methodId)
            }
            var writer: ImpulseTlWriter = ImpulseTlWriter()
            writer.writeInt32(value: Int32(bitPattern: method.id))
            let body: ImpulseBody = try parseBody(data: proto, offset: 0, length: proto.count)
            try decodeParams(
                params: method.params,
                captures: [],
                protoName: method.name,
                body: body,
                writer: &writer,
                captureHandler: nil,
                depth: 0
            )
            return writer.toByteArray()
        } catch {
            throw normalize(error, as: ImpulseTranscodeError.decodeFailed)
        }
    }


    private func normalize(
        _ error: Error,
        as kind: (String) -> ImpulseTranscodeError
    ) -> ImpulseTranscodeError {
        if let transcodeError: ImpulseTranscodeError = error as? ImpulseTranscodeError {
            if case .methodNotMapped = transcodeError {
                return transcodeError
            }
            return kind(transcodeError.reason)
        }
        return kind(String(describing: error))
    }


    private func checkDepth(depth: Int) throws {
        if depth > ImpulseTranscoder.maxDepth {
            throw ImpulseTranscodeError.encodeFailed("nesting too deep")
        }
    }


    private func readId(reader: inout ImpulseTlReader) throws -> UInt32 {
        let raw: Int32 = try reader.readInt32()
        return UInt32(bitPattern: raw)
    }


    private func requireConsumed(reader: ImpulseTlReader) throws {
        if reader.remaining != 0 {
            throw ImpulseTranscodeError.encodeFailed("\(reader.remaining) trailing bytes after TL object")
        }
    }


    private func tlBoolBits(value: Bool) -> Int32 {
        let bits: UInt32 = value ? ImpulseTlConstants.boolTrue : ImpulseTlConstants.boolFalse
        return Int32(bitPattern: bits)
    }


    private func bitMask(bit: Int) throws -> UInt32 {
        guard bit >= 0 && bit < 32 else {
            throw ImpulseTranscodeError.encodeFailed("flag bit \(bit) is out of range")
        }
        return UInt32(1) << UInt32(bit)
    }


    // MARK: TL to protobuf


    private func encodeRequestUnchecked(tl: [UInt8]) throws -> ImpulseEncodedRequest {
        var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
        var takeoutId: Int64? = nil
        while true {
            let id: UInt32 = try readId(reader: &reader)
            if id == ImpulseWrapperIds.invokeWithTakeout {
                takeoutId = try reader.readInt64()
                continue
            }
            let isWrapper: Bool = try skipWrapper(id: id, reader: &reader)
            if isWrapper {
                continue
            }
            guard let method: ImpulseMappingMethod = mapping.method(id: id) else {
                throw ImpulseTranscodeError.methodNotMapped(id)
            }
            var writer: ImpulseProtoWriter = ImpulseProtoWriter()
            try encodeParams(reader: &reader, params: method.params, writer: &writer, depth: 0)
            try requireConsumed(reader: reader)
            return ImpulseEncodedRequest(
                methodId: method.id,
                method: method.name,
                path: method.path,
                proto: writer.toByteArray(),
                takeoutId: takeoutId
            )
        }
    }


    /// Consumes a wrapper that the server does not need, so that the method behind it can be read. Returns false for
    /// any other id, and the reader is then left unchanged.
    private func skipWrapper(id: UInt32, reader: inout ImpulseTlReader) throws -> Bool {
        switch id {
        case ImpulseWrapperIds.invokeWithLayer:
            _ = try reader.readInt32()
            return true
        case ImpulseWrapperIds.invokeWithoutUpdates:
            return true
        case ImpulseWrapperIds.invokeAfterMsg:
            _ = try reader.readInt64()
            return true
        case ImpulseWrapperIds.invokeAfterMsgs:
            let vectorId: UInt32 = try readId(reader: &reader)
            guard vectorId == ImpulseTlConstants.vector else {
                throw ImpulseTranscodeError.encodeFailed("expected vector id after invokeAfterMsgs")
            }
            let count: Int32 = try reader.readInt32()
            guard count >= 0 else {
                throw ImpulseTranscodeError.encodeFailed("negative vector length in invokeAfterMsgs")
            }
            for _ in 0..<Int(count) {
                _ = try reader.readInt64()
            }
            return true
        case ImpulseWrapperIds.initConnection:
            let flags: Int32 = try reader.readInt32()
            _ = try reader.readInt32()
            for _ in 0..<6 {
                _ = try reader.readBytes()
            }
            if (flags & 1) != 0 {
                _ = try objectToProto(typeName: "InputClientProxy", reader: &reader, depth: 0)
            }
            if (flags & 2) != 0 {
                _ = try objectToProto(typeName: "JSONValue", reader: &reader, depth: 0)
            }
            return true
        case ImpulseWrapperIds.invokeWithMessagesRange:
            _ = try objectToProto(typeName: "MessageRange", reader: &reader, depth: 0)
            return true
        case ImpulseWrapperIds.invokeWithBusinessConnection:
            _ = try reader.readBytes()
            return true
        case ImpulseWrapperIds.invokeWithGooglePlayIntegrity, ImpulseWrapperIds.invokeWithApnsSecret:
            _ = try reader.readBytes()
            _ = try reader.readBytes()
            return true
        case ImpulseWrapperIds.invokeWithReCaptcha:
            _ = try reader.readBytes()
            return true
        default:
            return false
        }
    }


    private func objectToProto(
        typeName: String,
        reader: inout ImpulseTlReader,
        depth: Int
    ) throws -> [UInt8] {
        try checkDepth(depth: depth)
        let id: UInt32 = try readId(reader: &reader)
        guard let constructor: ImpulseMappingConstructor = mapping.constructor(id: id) else {
            throw ImpulseTranscodeError.encodeFailed(
                "unknown constructor " + String(id, radix: 16) + " while reading " + typeName
            )
        }
        guard constructor.typeName == typeName else {
            throw ImpulseTranscodeError.encodeFailed(
                "constructor " + constructor.predicate + " is " + constructor.typeName + ", expected " + typeName
            )
        }
        guard constructor.proto != nil else {
            throw ImpulseTranscodeError.encodeFailed("constructor " + constructor.predicate + " is not mapped")
        }
        var body: ImpulseProtoWriter = ImpulseProtoWriter()
        try encodeParams(reader: &reader, params: constructor.params, writer: &body, depth: depth)
        if let mappingType: ImpulseMappingType = mapping.type(named: typeName), mappingType.polymorphic {
            guard let arm: Int = constructor.arm else {
                throw ImpulseTranscodeError.encodeFailed("constructor " + constructor.predicate + " has no arm")
            }
            var wrapper: ImpulseProtoWriter = ImpulseProtoWriter()
            wrapper.writeBytesField(field: arm, value: body.toByteArray())
            return wrapper.toByteArray()
        }
        return body.toByteArray()
    }


    private func encodeParams(
        reader: inout ImpulseTlReader,
        params: [ImpulseMappingParam],
        writer: inout ImpulseProtoWriter,
        depth: Int
    ) throws {
        var registers: [String: UInt32] = [:]
        for param: ImpulseMappingParam in params {
            if param.kind == .flags {
                let register: Int32 = try reader.readInt32()
                registers[param.name] = UInt32(bitPattern: register)
                continue
            }
            if param.derivedFrom != nil {
                continue
            }
            if let flag: ImpulseMappingFlag = param.flag {
                guard let register: UInt32 = registers[flag.register] else {
                    throw ImpulseTranscodeError.encodeFailed("flag register " + flag.register + " is not declared")
                }
                let mask: UInt32 = try bitMask(bit: flag.bit)
                if (register & mask) == 0 {
                    continue
                }
            }
            if param.unmapped {
                throw ImpulseTranscodeError.encodeFailed("field " + param.name + " is not mapped by the server")
            }
            try encodeValue(reader: &reader, param: param, writer: &writer, depth: depth)
        }
    }


    private func encodeValue(
        reader: inout ImpulseTlReader,
        param: ImpulseMappingParam,
        writer: inout ImpulseProtoWriter,
        depth: Int
    ) throws {
        guard let field: Int = param.field else {
            throw ImpulseTranscodeError.encodeFailed("field " + param.name + " has no protobuf number")
        }
        switch param.kind {
        case .trueFlag:
            writer.writeVarintField(field: field, value: 1)
        case .bool:
            let flag: Bool = try readBool(reader: &reader)
            writer.writeVarintField(field: field, value: flag ? 1 : 0)
        case .int:
            let value: Int32 = try reader.readInt32()
            writer.writeInt32Field(field: field, value: value)
        case .long:
            let value: Int64 = try reader.readInt64()
            writer.writeInt64Field(field: field, value: value)
        case .double:
            let bits: Int64 = try reader.readInt64()
            writer.writeFixed64Field(field: field, bits: UInt64(bitPattern: bits))
        case .string, .bytes:
            let value: [UInt8] = try reader.readBytes()
            writer.writeBytesField(field: field, value: value)
        case .int128:
            let value: [UInt8] = try reader.readRaw(count: 16)
            writer.writeBytesField(field: field, value: value)
        case .int256:
            let value: [UInt8] = try reader.readRaw(count: 32)
            writer.writeBytesField(field: field, value: value)
        case .object:
            guard let typeName: String = param.typeName else {
                throw ImpulseTranscodeError.encodeFailed("object field " + param.name + " has no type")
            }
            let body: [UInt8] = try objectToProto(typeName: typeName, reader: &reader, depth: depth + 1)
            writer.writeBytesField(field: field, value: body)
        case .vector:
            try encodeVector(reader: &reader, param: param, field: field, writer: &writer, depth: depth)
        case .flags:
            throw ImpulseTranscodeError.encodeFailed("flags register " + param.name + " has no value")
        }
    }


    private func encodeVector(
        reader: inout ImpulseTlReader,
        param: ImpulseMappingParam,
        field: Int,
        writer: inout ImpulseProtoWriter,
        depth: Int
    ) throws {
        let vectorId: UInt32 = try readId(reader: &reader)
        guard vectorId == ImpulseTlConstants.vector else {
            throw ImpulseTranscodeError.encodeFailed("expected vector id in " + param.name)
        }
        let count: Int32 = try reader.readInt32()
        guard count >= 0, Int(count) <= reader.remaining else {
            throw ImpulseTranscodeError.encodeFailed("bad vector length \(count) in " + param.name)
        }
        if count == 0 {
            return
        }
        guard let element: ImpulseMappingElement = param.element else {
            throw ImpulseTranscodeError.encodeFailed("vector " + param.name + " has no element kind")
        }
        let total: Int = Int(count)
        switch element.kind {
        case .int:
            var values: [UInt64] = []
            for _ in 0..<total {
                let value: Int32 = try reader.readInt32()
                values.append(UInt64(bitPattern: Int64(value)))
            }
            writer.writePackedVarints(field: field, values: values)
        case .long:
            var values: [UInt64] = []
            for _ in 0..<total {
                let value: Int64 = try reader.readInt64()
                values.append(UInt64(bitPattern: value))
            }
            writer.writePackedVarints(field: field, values: values)
        case .bool:
            var values: [UInt64] = []
            for _ in 0..<total {
                let flag: Bool = try readBool(reader: &reader)
                values.append(flag ? 1 : 0)
            }
            writer.writePackedVarints(field: field, values: values)
        case .double:
            var bitsList: [UInt64] = []
            for _ in 0..<total {
                let bits: Int64 = try reader.readInt64()
                bitsList.append(UInt64(bitPattern: bits))
            }
            writer.writePackedFixed64(field: field, bitsList: bitsList)
        case .string, .bytes:
            for _ in 0..<total {
                let value: [UInt8] = try reader.readBytes()
                writer.writeBytesField(field: field, value: value)
            }
        case .int128:
            for _ in 0..<total {
                let value: [UInt8] = try reader.readRaw(count: 16)
                writer.writeBytesField(field: field, value: value)
            }
        case .int256:
            for _ in 0..<total {
                let value: [UInt8] = try reader.readRaw(count: 32)
                writer.writeBytesField(field: field, value: value)
            }
        case .object:
            guard let typeName: String = element.typeName else {
                throw ImpulseTranscodeError.encodeFailed("vector element of " + param.name + " has no type")
            }
            for _ in 0..<total {
                let body: [UInt8] = try objectToProto(typeName: typeName, reader: &reader, depth: depth + 1)
                writer.writeBytesField(field: field, value: body)
            }
        case .trueFlag, .flags, .vector:
            throw ImpulseTranscodeError.encodeFailed("unsupported vector element in " + param.name)
        }
    }


    private func readBool(reader: inout ImpulseTlReader) throws -> Bool {
        let id: UInt32 = try readId(reader: &reader)
        if id == ImpulseTlConstants.boolTrue {
            return true
        }
        if id == ImpulseTlConstants.boolFalse {
            return false
        }
        throw ImpulseTranscodeError.encodeFailed("bad Bool id " + String(id, radix: 16))
    }


    // MARK: protobuf to TL


    private func decodeResultSpec(
        result: ImpulseMappingResult,
        proto: [UInt8],
        captureHandler: ImpulseCaptureHandler?
    ) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        switch result.kind {
        case .bool:
            let body: ImpulseBody = try parseBody(data: proto, offset: 0, length: proto.count)
            guard let occurrence: ImpulseOccurrence = body.fields[1]?.last else {
                throw ImpulseTranscodeError.responseParseFailed("Bool result carries no value")
            }
            writer.writeInt32(value: tlBoolBits(value: occurrence.value != 0))
        case .list:
            let body: ImpulseBody = try parseBody(data: proto, offset: 0, length: proto.count)
            guard let element: ImpulseMappingElement = result.element else {
                throw ImpulseTranscodeError.responseParseFailed("list result has no element kind")
            }
            let occurrences: [ImpulseOccurrence] = body.fields[1] ?? []
            try writeVector(
                writer: &writer,
                element: element,
                body: body,
                occurrences: occurrences,
                captureHandler: captureHandler,
                depth: 0
            )
        case .object:
            guard let typeName: String = result.typeName else {
                throw ImpulseTranscodeError.responseParseFailed("object result has no type")
            }
            try protoToObject(
                typeName: typeName,
                data: proto,
                offset: 0,
                length: proto.count,
                writer: &writer,
                captureHandler: captureHandler,
                depth: 0
            )
        }
        return writer.toByteArray()
    }


    private func protoToObject(
        typeName: String,
        data: [UInt8],
        offset: Int,
        length: Int,
        writer: inout ImpulseTlWriter,
        captureHandler: ImpulseCaptureHandler?,
        depth: Int
    ) throws {
        try checkDepth(depth: depth)
        let resolved: ImpulseResolvedConstructor = try resolveConstructor(
            typeName: typeName,
            data: data,
            offset: offset,
            length: length
        )
        let constructor: ImpulseMappingConstructor = resolved.constructor
        guard let protoName: String = constructor.proto else {
            throw ImpulseTranscodeError.decodeFailed("constructor " + constructor.predicate + " is not mapped")
        }
        let body: ImpulseBody = try parseBody(data: data, offset: resolved.offset, length: resolved.length)
        writer.writeInt32(value: Int32(bitPattern: constructor.id))
        try decodeParams(
            params: constructor.params,
            captures: constructor.captures,
            protoName: protoName,
            body: body,
            writer: &writer,
            captureHandler: captureHandler,
            depth: depth
        )
    }


    /// Picks the constructor of a protobuf object. A polymorphic type is selected by its first known arm; any other
    /// type has exactly one constructor.
    private func resolveConstructor(
        typeName: String,
        data: [UInt8],
        offset: Int,
        length: Int
    ) throws -> ImpulseResolvedConstructor {
        guard let mappingType: ImpulseMappingType = mapping.type(named: typeName) else {
            throw ImpulseTranscodeError.decodeFailed("unknown type " + typeName)
        }
        if !mappingType.polymorphic {
            let candidates: [ImpulseMappingConstructor] = constructorsByType[typeName] ?? []
            guard candidates.count == 1, let only: ImpulseMappingConstructor = candidates.first else {
                throw ImpulseTranscodeError.decodeFailed(
                    "type " + typeName + " has \(candidates.count) constructors but is not polymorphic"
                )
            }
            return ImpulseResolvedConstructor(constructor: only, offset: offset, length: length)
        }
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: offset, length: length)
        while try reader.next() {
            let arm: Int = reader.field
            if reader.wireType == 2 && mappingType.arms[arm] != nil {
                let range: Range<Int> = try reader.readLengthDelimitedRange()
                guard let armConstructor: ImpulseMappingConstructor = mapping.constructor(ofType: typeName, arm: arm) else {
                    throw ImpulseTranscodeError.decodeFailed("unset oneof for " + typeName)
                }
                return ImpulseResolvedConstructor(
                    constructor: armConstructor,
                    offset: range.lowerBound,
                    length: range.count
                )
            }
        }
        throw ImpulseTranscodeError.decodeFailed("unset oneof for " + typeName)
    }


    private func decodeParams(
        params: [ImpulseMappingParam],
        captures: [ImpulseMappingCapture],
        protoName: String,
        body: ImpulseBody,
        writer: inout ImpulseTlWriter,
        captureHandler: ImpulseCaptureHandler?,
        depth: Int
    ) throws {
        var registers: [String: UInt32] = [:]
        for param: ImpulseMappingParam in params where param.kind == .flags {
            registers[param.name] = 0
        }
        for param: ImpulseMappingParam in params {
            guard let flag: ImpulseMappingFlag = param.flag else {
                continue
            }
            var source: ImpulseMappingParam = param
            if let derivedName: String = param.derivedFrom {
                source = try findParam(params: params, name: derivedName)
            }
            guard let register: UInt32 = registers[flag.register] else {
                throw ImpulseTranscodeError.decodeFailed("flag register " + flag.register + " is not declared")
            }
            if isPresent(param: source, body: body) {
                let mask: UInt32 = try bitMask(bit: flag.bit)
                registers[flag.register] = register | mask
            }
        }
        if let handler: ImpulseCaptureHandler = captureHandler {
            for capture: ImpulseMappingCapture in captures {
                if let last: ImpulseOccurrence = body.fields[capture.field]?.last {
                    handler(protoName, capture.name, utf8(body: body, occurrence: last))
                }
            }
        }
        for param: ImpulseMappingParam in params {
            if param.kind == .flags {
                let register: UInt32 = registers[param.name] ?? 0
                writer.writeInt32(value: Int32(bitPattern: register))
                continue
            }
            if param.derivedFrom != nil {
                continue
            }
            if let flag: ImpulseMappingFlag = param.flag {
                let register: UInt32 = registers[flag.register] ?? 0
                let mask: UInt32 = try bitMask(bit: flag.bit)
                if (register & mask) == 0 {
                    continue
                }
            }
            try decodeValue(
                param: param,
                body: body,
                writer: &writer,
                captureHandler: captureHandler,
                depth: depth
            )
        }
    }


    private func decodeValue(
        param: ImpulseMappingParam,
        body: ImpulseBody,
        writer: inout ImpulseTlWriter,
        captureHandler: ImpulseCaptureHandler?,
        depth: Int
    ) throws {
        guard let field: Int = param.field else {
            throw ImpulseTranscodeError.decodeFailed("field " + param.name + " is not mapped by the server")
        }
        let occurrences: [ImpulseOccurrence] = body.fields[field] ?? []
        let last: ImpulseOccurrence? = occurrences.last
        switch param.kind {
        case .trueFlag:
            break
        case .bool:
            let isTrue: Bool = (last?.value ?? 0) != 0
            writer.writeInt32(value: tlBoolBits(value: isTrue))
        case .int:
            let value: UInt64 = try numericValue(param: param, occurrence: last)
            writer.writeInt32(value: Int32(truncatingIfNeeded: value))
        case .long:
            let value: UInt64 = try numericValue(param: param, occurrence: last)
            writer.writeInt64(value: Int64(bitPattern: value))
        case .double:
            var bits: UInt64 = 0
            if let occurrence: ImpulseOccurrence = last {
                guard occurrence.wire == 1 else {
                    throw ImpulseTranscodeError.decodeFailed("field " + param.name + " must be fixed64")
                }
                bits = occurrence.value
            }
            writer.writeInt64(value: Int64(bitPattern: bits))
        case .string, .bytes:
            let bytes: [UInt8] = try lengthDelimitedBytes(param: param, body: body, occurrence: last)
            try writer.writeBytes(value: bytes)
        case .int128:
            let bytes: [UInt8] = try fixedBytes(name: param.name, body: body, occurrence: last, expected: 16)
            writer.writeRaw(value: bytes)
        case .int256:
            let bytes: [UInt8] = try fixedBytes(name: param.name, body: body, occurrence: last, expected: 32)
            writer.writeRaw(value: bytes)
        case .object:
            guard let occurrence: ImpulseOccurrence = last else {
                throw ImpulseTranscodeError.decodeFailed(
                    "missing required object field " + param.name + " of type " + (param.typeName ?? "")
                )
            }
            guard occurrence.wire == 2 else {
                throw ImpulseTranscodeError.decodeFailed("field " + param.name + " must be length-delimited")
            }
            guard let typeName: String = param.typeName else {
                throw ImpulseTranscodeError.decodeFailed("object field " + param.name + " has no type")
            }
            try protoToObject(
                typeName: typeName,
                data: body.data,
                offset: occurrence.offset,
                length: occurrence.length,
                writer: &writer,
                captureHandler: captureHandler,
                depth: depth + 1
            )
        case .vector:
            guard let element: ImpulseMappingElement = param.element else {
                throw ImpulseTranscodeError.decodeFailed("vector " + param.name + " has no element kind")
            }
            try writeVector(
                writer: &writer,
                element: element,
                body: body,
                occurrences: occurrences,
                captureHandler: captureHandler,
                depth: depth
            )
        case .flags:
            throw ImpulseTranscodeError.decodeFailed("flags register " + param.name + " has no value")
        }
    }


    private func writeVector(
        writer: inout ImpulseTlWriter,
        element: ImpulseMappingElement,
        body: ImpulseBody,
        occurrences: [ImpulseOccurrence],
        captureHandler: ImpulseCaptureHandler?,
        depth: Int
    ) throws {
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        switch element.kind {
        case .int, .long, .bool:
            let values: [UInt64] = try packedVarints(body: body, occurrences: occurrences)
            writer.writeInt32(value: Int32(values.count))
            for value: UInt64 in values {
                if element.kind == .long {
                    writer.writeInt64(value: Int64(bitPattern: value))
                } else if element.kind == .bool {
                    writer.writeInt32(value: tlBoolBits(value: value != 0))
                } else {
                    writer.writeInt32(value: Int32(truncatingIfNeeded: value))
                }
            }
        case .double:
            let values: [UInt64] = try packedFixed64(body: body, occurrences: occurrences)
            writer.writeInt32(value: Int32(values.count))
            for value: UInt64 in values {
                writer.writeInt64(value: Int64(bitPattern: value))
            }
        case .string, .bytes, .int128, .int256, .object:
            writer.writeInt32(value: Int32(occurrences.count))
            for occurrence: ImpulseOccurrence in occurrences {
                guard occurrence.wire == 2 else {
                    throw ImpulseTranscodeError.decodeFailed("vector element must be length-delimited")
                }
                switch element.kind {
                case .object:
                    guard let typeName: String = element.typeName else {
                        throw ImpulseTranscodeError.decodeFailed("vector element has no type")
                    }
                    try protoToObject(
                        typeName: typeName,
                        data: body.data,
                        offset: occurrence.offset,
                        length: occurrence.length,
                        writer: &writer,
                        captureHandler: captureHandler,
                        depth: depth + 1
                    )
                case .int128:
                    let bytes: [UInt8] = try fixedBytes(name: "vector element", body: body, occurrence: occurrence, expected: 16)
                    writer.writeRaw(value: bytes)
                case .int256:
                    let bytes: [UInt8] = try fixedBytes(name: "vector element", body: body, occurrence: occurrence, expected: 32)
                    writer.writeRaw(value: bytes)
                default:
                    let bytes: [UInt8] = Array(body.data[occurrence.offset..<(occurrence.offset + occurrence.length)])
                    try writer.writeBytes(value: bytes)
                }
            }
        case .trueFlag, .flags, .vector:
            throw ImpulseTranscodeError.decodeFailed("unsupported vector element")
        }
    }


    private func packedVarints(body: ImpulseBody, occurrences: [ImpulseOccurrence]) throws -> [UInt64] {
        var values: [UInt64] = []
        for occurrence: ImpulseOccurrence in occurrences {
            if occurrence.wire == 2 {
                var reader: ImpulseProtoReader = try ImpulseProtoReader(
                    data: body.data,
                    offset: occurrence.offset,
                    length: occurrence.length
                )
                while reader.hasMore {
                    let value: UInt64 = try reader.readVarint()
                    values.append(value)
                }
            } else if occurrence.wire == 0 || occurrence.wire == 5 {
                values.append(occurrence.value)
            } else {
                throw ImpulseTranscodeError.decodeFailed("bad wire type \(occurrence.wire) for a packed vector")
            }
        }
        return values
    }


    private func packedFixed64(body: ImpulseBody, occurrences: [ImpulseOccurrence]) throws -> [UInt64] {
        var values: [UInt64] = []
        for occurrence: ImpulseOccurrence in occurrences {
            if occurrence.wire == 2 {
                guard occurrence.length % 8 == 0 else {
                    throw ImpulseTranscodeError.decodeFailed("packed double blob has length \(occurrence.length)")
                }
                var position: Int = 0
                while position < occurrence.length {
                    var bits: UInt64 = 0
                    for index: Int in (0..<8).reversed() {
                        bits = (bits << 8) | UInt64(body.data[occurrence.offset + position + index])
                    }
                    values.append(bits)
                    position += 8
                }
            } else if occurrence.wire == 1 {
                values.append(occurrence.value)
            } else {
                throw ImpulseTranscodeError.decodeFailed("bad wire type \(occurrence.wire) for a packed double vector")
            }
        }
        return values
    }


    private func numericValue(param: ImpulseMappingParam, occurrence: ImpulseOccurrence?) throws -> UInt64 {
        guard let occurrence: ImpulseOccurrence = occurrence else {
            return 0
        }
        guard occurrence.wire == 0 || occurrence.wire == 1 || occurrence.wire == 5 else {
            throw ImpulseTranscodeError.decodeFailed("field " + param.name + " must be numeric")
        }
        return occurrence.value
    }


    private func lengthDelimitedBytes(
        param: ImpulseMappingParam,
        body: ImpulseBody,
        occurrence: ImpulseOccurrence?
    ) throws -> [UInt8] {
        guard let occurrence: ImpulseOccurrence = occurrence else {
            return []
        }
        guard occurrence.wire == 2 else {
            throw ImpulseTranscodeError.decodeFailed("field " + param.name + " must be length-delimited")
        }
        return Array(body.data[occurrence.offset..<(occurrence.offset + occurrence.length)])
    }


    private func fixedBytes(
        name: String,
        body: ImpulseBody,
        occurrence: ImpulseOccurrence?,
        expected: Int
    ) throws -> [UInt8] {
        guard let occurrence: ImpulseOccurrence = occurrence else {
            throw ImpulseTranscodeError.decodeFailed("field " + name + " must be \(expected) bytes, got 0")
        }
        guard occurrence.wire == 2 else {
            throw ImpulseTranscodeError.decodeFailed("field " + name + " must be length-delimited")
        }
        guard occurrence.length == expected else {
            throw ImpulseTranscodeError.decodeFailed("field " + name + " must be \(expected) bytes, got \(occurrence.length)")
        }
        return Array(body.data[occurrence.offset..<(occurrence.offset + expected)])
    }


    private func parseBody(data: [UInt8], offset: Int, length: Int) throws -> ImpulseBody {
        var reader: ImpulseProtoReader = try ImpulseProtoReader(data: data, offset: offset, length: length)
        var fields: [Int: [ImpulseOccurrence]] = [:]
        while try reader.next() {
            let field: Int = reader.field
            let occurrence: ImpulseOccurrence = try readOccurrence(reader: &reader)
            fields[field, default: []].append(occurrence)
        }
        return ImpulseBody(data: data, fields: fields)
    }


    private func readOccurrence(reader: inout ImpulseProtoReader) throws -> ImpulseOccurrence {
        let wire: Int = reader.wireType
        switch wire {
        case 0:
            let value: UInt64 = try reader.readVarint()
            return ImpulseOccurrence(wire: 0, value: value, offset: 0, length: 0)
        case 1:
            let value: UInt64 = try reader.readFixed64()
            return ImpulseOccurrence(wire: 1, value: value, offset: 0, length: 0)
        case 2:
            let range: Range<Int> = try reader.readLengthDelimitedRange()
            return ImpulseOccurrence(wire: 2, value: 0, offset: range.lowerBound, length: range.count)
        case 5:
            let value: UInt32 = try reader.readFixed32()
            return ImpulseOccurrence(wire: 5, value: UInt64(value), offset: 0, length: 0)
        default:
            throw ImpulseTranscodeError.decodeFailed("unsupported protobuf wire type \(wire)")
        }
    }


    private func findParam(params: [ImpulseMappingParam], name: String) throws -> ImpulseMappingParam {
        for candidate: ImpulseMappingParam in params where candidate.name == name {
            return candidate
        }
        throw ImpulseTranscodeError.decodeFailed("derived_from references unknown param " + name)
    }


    /// True when the protobuf body carries the value of a param, which sets its flag bit on decode.
    private func isPresent(param: ImpulseMappingParam, body: ImpulseBody) -> Bool {
        guard let field: Int = param.field else {
            return false
        }
        guard let occurrences: [ImpulseOccurrence] = body.fields[field], !occurrences.isEmpty else {
            return false
        }
        if param.kind == .trueFlag {
            return (occurrences.last?.value ?? 0) != 0
        }
        if param.kind == .vector, let element: ImpulseMappingElement = param.element, isPackable(kind: element.kind) {
            for occurrence: ImpulseOccurrence in occurrences {
                if occurrence.wire != 2 || occurrence.length > 0 {
                    return true
                }
            }
            return false
        }
        return true
    }


    private func isPackable(kind: ImpulseMappingKind) -> Bool {
        return kind == .int || kind == .long || kind == .bool || kind == .double
    }


    private func utf8(body: ImpulseBody, occurrence: ImpulseOccurrence) -> String {
        let slice: ArraySlice<UInt8> = body.data[occurrence.offset..<(occurrence.offset + occurrence.length)]
        return String(decoding: slice, as: UTF8.self)
    }
}


fileprivate struct ImpulseOccurrence {
    let wire: Int
    let value: UInt64
    let offset: Int
    let length: Int
}


fileprivate struct ImpulseBody {
    let data: [UInt8]
    let fields: [Int: [ImpulseOccurrence]]
}


fileprivate struct ImpulseResolvedConstructor {
    let constructor: ImpulseMappingConstructor
    let offset: Int
    let length: Int
}
