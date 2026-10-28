@testable import ImpulseTransport


/// Test helper: deterministic bare TL for any mapped constructor or method.
/// Params the server mapping lacks, and flagged params whose object type has no mapped constructor, are left out
/// because the transcoder rejects them by design.
struct ImpulseTlSynth {
    private static let guardDepth: Int = 4
    private static let hardDepth: Int = 16


    private let simplestByType: [String: ImpulseMappingConstructor]


    init(mapping: ImpulseMapping) {
        var simplest: [String: ImpulseMappingConstructor] = [:]
        for constructor: ImpulseMappingConstructor in mapping.constructors where constructor.proto != nil {
            if let current: ImpulseMappingConstructor = simplest[constructor.typeName] {
                if ImpulseTlSynth.isSimpler(constructor, than: current) {
                    simplest[constructor.typeName] = constructor
                }
            } else {
                simplest[constructor.typeName] = constructor
            }
        }
        self.simplestByType = simplest
    }


    func simplestConstructor(typeName: String) -> ImpulseMappingConstructor? {
        return simplestByType[typeName]
    }


    func constructorTl(constructor: ImpulseMappingConstructor, allFlags: Bool) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: constructor.id))
        try writeParams(writer: &writer, params: constructor.params, allFlags: allFlags, depth: 0)
        return writer.toByteArray()
    }


    func methodTl(method: ImpulseMappingMethod, allFlags: Bool) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: Int32(bitPattern: method.id))
        try writeParams(writer: &writer, params: method.params, allFlags: allFlags, depth: 0)
        return writer.toByteArray()
    }


    private static func isSimpler(
        _ candidate: ImpulseMappingConstructor,
        than current: ImpulseMappingConstructor
    ) -> Bool {
        if candidate.params.count != current.params.count {
            return candidate.params.count < current.params.count
        }
        return candidate.id < current.id
    }


    private func isSynthesizable(typeName: String) -> Bool {
        return simplestByType[typeName] != nil
    }


    private func referencedTypeName(param: ImpulseMappingParam) -> String? {
        if param.kind == .object {
            return param.typeName
        }
        if param.kind == .vector, let element: ImpulseMappingElement = param.element, element.kind == .object {
            return element.typeName
        }
        return nil
    }


    private func isOmitted(param: ImpulseMappingParam) -> Bool {
        if param.unmapped {
            return true
        }
        guard param.flag != nil else {
            return false
        }
        if let typeName: String = referencedTypeName(param: param) {
            return !isSynthesizable(typeName: typeName)
        }
        return false
    }


    private func writeParams(
        writer: inout ImpulseTlWriter,
        params: [ImpulseMappingParam],
        allFlags: Bool,
        depth: Int
    ) throws {
        var registers: [String: UInt32] = [:]
        for param: ImpulseMappingParam in params where param.kind == .flags {
            registers[param.name] = 0
        }
        if allFlags {
            for param: ImpulseMappingParam in params {
                guard let flag: ImpulseMappingFlag = param.flag, !isOmitted(param: param) else {
                    continue
                }
                registers[flag.register, default: 0] |= UInt32(1) << UInt32(flag.bit)
            }
        }
        for param: ImpulseMappingParam in params {
            if param.kind == .flags {
                writer.writeInt32(value: Int32(bitPattern: registers[param.name] ?? 0))
                continue
            }
            if param.derivedFrom != nil || isOmitted(param: param) {
                continue
            }
            if param.flag != nil && !allFlags {
                continue
            }
            try writeParamValue(writer: &writer, param: param, allFlags: allFlags, depth: depth)
        }
    }


    private func writeParamValue(
        writer: inout ImpulseTlWriter,
        param: ImpulseMappingParam,
        allFlags: Bool,
        depth: Int
    ) throws {
        if param.kind == .vector {
            try writeVector(writer: &writer, param: param, allFlags: allFlags, depth: depth)
            return
        }
        try writeScalar(
            writer: &writer,
            kind: param.kind,
            typeName: param.typeName,
            name: param.name,
            allFlags: allFlags,
            depth: depth
        )
    }


    private func writeVector(
        writer: inout ImpulseTlWriter,
        param: ImpulseMappingParam,
        allFlags: Bool,
        depth: Int
    ) throws {
        writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.vector))
        guard let element: ImpulseMappingElement = param.element else {
            throw ImpulseTlSynthError.failed("vector " + param.name + " has no element")
        }
        if depth >= ImpulseTlSynth.guardDepth {
            writer.writeInt32(value: 0)
            return
        }
        writer.writeInt32(value: 2)
        try writeScalar(
            writer: &writer,
            kind: element.kind,
            typeName: element.typeName,
            name: param.name,
            allFlags: allFlags,
            depth: depth
        )
        try writeScalar(
            writer: &writer,
            kind: element.kind,
            typeName: element.typeName,
            name: param.name + "2",
            allFlags: allFlags,
            depth: depth
        )
    }


    private func writeScalar(
        writer: inout ImpulseTlWriter,
        kind: ImpulseMappingKind,
        typeName: String?,
        name: String,
        allFlags: Bool,
        depth: Int
    ) throws {
        switch kind {
        case .trueFlag:
            break
        case .bool:
            writer.writeInt32(value: Int32(bitPattern: ImpulseTlConstants.boolTrue))
        case .int:
            writer.writeInt32(value: 7)
        case .long:
            writer.writeInt64(value: 1234567890123)
        case .double:
            writer.writeDouble(value: 1.5)
        case .string:
            try writer.writeString(value: "s_" + name)
        case .bytes:
            try writer.writeBytes(value: [1, 2, 3])
        case .int128:
            writer.writeRaw(value: [UInt8](repeating: 0x11, count: 16))
        case .int256:
            writer.writeRaw(value: [UInt8](repeating: 0x22, count: 32))
        case .object:
            guard let objectType: String = typeName else {
                throw ImpulseTlSynthError.failed("object " + name + " has no type")
            }
            try writeObject(writer: &writer, typeName: objectType, allFlags: allFlags, depth: depth)
        case .vector, .flags:
            throw ImpulseTlSynthError.failed("cannot synthesize " + name)
        }
    }


    private func writeObject(
        writer: inout ImpulseTlWriter,
        typeName: String,
        allFlags: Bool,
        depth: Int
    ) throws {
        if depth > ImpulseTlSynth.hardDepth {
            throw ImpulseTlSynthError.failed("synthesis recursion for " + typeName)
        }
        guard let constructor: ImpulseMappingConstructor = simplestByType[typeName] else {
            throw ImpulseTlSynthError.failed("no mapped constructor for " + typeName)
        }
        let nestedFlags: Bool = depth >= ImpulseTlSynth.guardDepth ? false : allFlags
        writer.writeInt32(value: Int32(bitPattern: constructor.id))
        try writeParams(writer: &writer, params: constructor.params, allFlags: nestedFlags, depth: depth + 1)
    }
}


enum ImpulseTlSynthError: Error {
    case failed(String)
}
