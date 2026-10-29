import Foundation


public enum ImpulseMappingError: Error, Equatable {
    case resourceMissing(String)
    case unknownParamKind(String)
    case unknownResultKind(String)
    case invalidArm(String)
    case duplicateConstructorId(UInt32)
    case duplicateMethodId(UInt32)
    case duplicateMethodName(String)
    case duplicateTypeName(String)
}


public enum ImpulseTlConstants {
    public static let vector: UInt32 = 0x1cb5c415
    public static let boolTrue: UInt32 = 0x997275b5
    public static let boolFalse: UInt32 = 0xbc799737
}


public enum ImpulseWrapperIds {
    public static let invokeAfterMsg: UInt32 = 0xcb9f372d
    public static let invokeAfterMsgs: UInt32 = 0x3dc4b4f0
    public static let initConnection: UInt32 = 0xc1cd5ea9
    public static let invokeWithLayer: UInt32 = 0xda9b0d0d
    public static let invokeWithoutUpdates: UInt32 = 0xbf9459b7
    public static let invokeWithMessagesRange: UInt32 = 0x365275f2
    public static let invokeWithTakeout: UInt32 = 0xaca9fd2e
    public static let invokeWithBusinessConnection: UInt32 = 0xdd289f8e
    public static let invokeWithGooglePlayIntegrity: UInt32 = 0x1df92984
    public static let invokeWithApnsSecret: UInt32 = 0x0dae54f8
    public static let invokeWithReCaptcha: UInt32 = 0xadbb0f94
}


public enum ImpulseMappingKind: String, Equatable, Sendable {
    case int
    case long
    case double
    case string
    case bytes
    case int128
    case int256
    case bool
    case trueFlag = "true"
    case flags
    case vector
    case object
}


public enum ImpulseMappingResultKind: String, Equatable, Sendable {
    case object
    case bool
    case list
}


public struct ImpulseMappingElement: Equatable, Sendable {
    public let kind: ImpulseMappingKind
    public let typeName: String?
}


public struct ImpulseMappingFlag: Equatable, Sendable {
    public let register: String
    public let bit: Int
}


public struct ImpulseMappingCapture: Equatable, Sendable {
    public let field: Int
    public let name: String
}


public struct ImpulseMappingParam: Equatable, Sendable {
    public let name: String
    public let kind: ImpulseMappingKind
    public let typeName: String?
    public let field: Int?
    public let flag: ImpulseMappingFlag?
    public let element: ImpulseMappingElement?
    public let derivedFrom: String?
    public let unmapped: Bool
}


public struct ImpulseMappingConstructor: Equatable, Sendable {
    public let id: UInt32
    public let predicate: String
    public let typeName: String
    public let proto: String?
    public let arm: Int?
    public let params: [ImpulseMappingParam]
    public let captures: [ImpulseMappingCapture]
}


public struct ImpulseMappingType: Equatable, Sendable {
    public let name: String
    public let proto: String?
    public let polymorphic: Bool
    public let arms: [Int: UInt32]
}


public struct ImpulseMappingResult: Equatable, Sendable {
    public let kind: ImpulseMappingResultKind
    public let typeName: String?
    public let element: ImpulseMappingElement?
}


public struct ImpulseMappingMethod: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let path: String
    public let params: [ImpulseMappingParam]
    public let result: ImpulseMappingResult
}


public struct ImpulseMapping: Sendable {
    public let layer: Int
    public let constants: [String: UInt32]
    public let wrappers: [String: UInt32]
    public let constructors: [ImpulseMappingConstructor]
    public let methods: [ImpulseMappingMethod]
    public let types: [ImpulseMappingType]

    private let constructorIndex: [UInt32: Int]
    private let methodIdIndex: [UInt32: Int]
    private let methodNameIndex: [String: Int]
    private let typeIndex: [String: Int]


    private init(
        layer: Int,
        constants: [String: UInt32],
        wrappers: [String: UInt32],
        constructors: [ImpulseMappingConstructor],
        methods: [ImpulseMappingMethod],
        types: [ImpulseMappingType]
    ) throws {
        var constructorIndex: [UInt32: Int] = [:]
        for index: Int in constructors.indices {
            let constructor: ImpulseMappingConstructor = constructors[index]
            if constructorIndex[constructor.id] != nil {
                throw ImpulseMappingError.duplicateConstructorId(constructor.id)
            }
            constructorIndex[constructor.id] = index
        }

        var methodIdIndex: [UInt32: Int] = [:]
        var methodNameIndex: [String: Int] = [:]
        for index: Int in methods.indices {
            let method: ImpulseMappingMethod = methods[index]
            if methodIdIndex[method.id] != nil {
                throw ImpulseMappingError.duplicateMethodId(method.id)
            }
            if methodNameIndex[method.name] != nil {
                throw ImpulseMappingError.duplicateMethodName(method.name)
            }
            methodIdIndex[method.id] = index
            methodNameIndex[method.name] = index
        }

        var typeIndex: [String: Int] = [:]
        for index: Int in types.indices {
            let mappingType: ImpulseMappingType = types[index]
            if typeIndex[mappingType.name] != nil {
                throw ImpulseMappingError.duplicateTypeName(mappingType.name)
            }
            typeIndex[mappingType.name] = index
        }

        self.layer = layer
        self.constants = constants
        self.wrappers = wrappers
        self.constructors = constructors
        self.methods = methods
        self.types = types
        self.constructorIndex = constructorIndex
        self.methodIdIndex = methodIdIndex
        self.methodNameIndex = methodNameIndex
        self.typeIndex = typeIndex
    }


    public static func loadBundled() throws -> ImpulseMapping {
        let url: URL = try ImpulseMapping.bundledResourceUrl()
        let data: Data = try Data(contentsOf: url)
        return try ImpulseMapping.parse(data: data)
    }


    public static func parse(data: Data) throws -> ImpulseMapping {
        let decoder: JSONDecoder = JSONDecoder()
        let raw: RawMapping = try decoder.decode(RawMapping.self, from: data)

        var constructors: [ImpulseMappingConstructor] = []
        for rawConstructor: RawConstructor in raw.constructors {
            constructors.append(try ImpulseMapping.makeConstructor(raw: rawConstructor))
        }

        var methods: [ImpulseMappingMethod] = []
        for rawMethod: RawMethod in raw.methods {
            methods.append(try ImpulseMapping.makeMethod(raw: rawMethod))
        }

        var types: [ImpulseMappingType] = []
        for rawType: RawType in raw.types {
            types.append(try ImpulseMapping.makeType(raw: rawType))
        }

        return try ImpulseMapping(
            layer: raw.layer,
            constants: raw.constants,
            wrappers: raw.wrappers,
            constructors: constructors,
            methods: methods,
            types: types
        )
    }


    public func constructor(id: UInt32) -> ImpulseMappingConstructor? {
        guard let index: Int = constructorIndex[id] else {
            return nil
        }

        return self.constructors[index]
    }


    public func method(id: UInt32) -> ImpulseMappingMethod? {
        guard let index: Int = methodIdIndex[id] else {
            return nil
        }

        return methods[index]
    }


    public func method(name: String) -> ImpulseMappingMethod? {
        guard let index: Int = methodNameIndex[name] else {
            return nil
        }

        return methods[index]
    }


    public func type(named name: String) -> ImpulseMappingType? {
        guard let index: Int = typeIndex[name] else {
            return nil
        }

        return types[index]
    }


    public func constructors(ofType typeName: String) -> [ImpulseMappingConstructor] {
        return self.constructors.filter { (candidate: ImpulseMappingConstructor) -> Bool in
            return candidate.typeName == typeName
        }
    }


    public func constructor(
        ofType typeName: String,
        arm: Int
    ) -> ImpulseMappingConstructor? {
        guard let mappingType: ImpulseMappingType = type(named: typeName) else {
            return nil
        }

        guard let id: UInt32 = mappingType.arms[arm] else {
            return nil
        }

        return constructor(id: id)
    }


    private static func bundledResourceUrl() throws -> URL {
        let resourceName: String = "tl-proto-232"
        let resourceExtension: String = "json"

        #if SWIFT_PACKAGE
        let resourceBundle: Bundle = Bundle.module
        #else
        let resourceBundle: Bundle = Bundle(for: ImpulseMappingBundleAnchor.self)
        #endif

        if let nested: URL = resourceBundle.url(
            forResource: resourceName,
            withExtension: resourceExtension,
            subdirectory: "Resources"
        ) {
            return nested
        }

        if let flat: URL = resourceBundle.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ) {
            return flat
        }

        throw ImpulseMappingError.resourceMissing(resourceName + "." + resourceExtension)
    }


    private static func makeKind(raw: String) throws -> ImpulseMappingKind {
        guard let kind: ImpulseMappingKind = ImpulseMappingKind(rawValue: raw.lowercased()) else {
            throw ImpulseMappingError.unknownParamKind(raw)
        }

        return kind
    }


    private static func makeResultKind(raw: String) throws -> ImpulseMappingResultKind {
        guard let kind: ImpulseMappingResultKind = ImpulseMappingResultKind(rawValue: raw.lowercased()) else {
            throw ImpulseMappingError.unknownResultKind(raw)
        }

        return kind
    }


    private static func makeElement(raw: RawElement) throws -> ImpulseMappingElement {
        let kind: ImpulseMappingKind = try ImpulseMapping.makeKind(raw: raw.kind)
        return ImpulseMappingElement(kind: kind, typeName: raw.typeName)
    }


    private static func makeParam(raw: RawParam) throws -> ImpulseMappingParam {
        let kind: ImpulseMappingKind = try ImpulseMapping.makeKind(raw: raw.kind)

        var flag: ImpulseMappingFlag? = nil
        if let rawFlag: RawFlag = raw.flag {
            flag = ImpulseMappingFlag(register: rawFlag.register, bit: rawFlag.bit)
        }

        var element: ImpulseMappingElement? = nil
        if let rawElement: RawElement = raw.elem {
            element = try ImpulseMapping.makeElement(raw: rawElement)
        }

        return ImpulseMappingParam(
            name: raw.name,
            kind: kind,
            typeName: raw.typeName,
            field: raw.field,
            flag: flag,
            element: element,
            derivedFrom: raw.derivedFrom,
            unmapped: raw.unmapped ?? false
        )
    }


    private static func makeConstructor(raw: RawConstructor) throws -> ImpulseMappingConstructor {
        var params: [ImpulseMappingParam] = []
        for rawParam: RawParam in raw.params {
            params.append(try ImpulseMapping.makeParam(raw: rawParam))
        }

        var captures: [ImpulseMappingCapture] = []
        for rawCapture: RawCapture in raw.capture ?? [] {
            captures.append(ImpulseMappingCapture(field: rawCapture.field, name: rawCapture.name))
        }

        return ImpulseMappingConstructor(
            id: raw.id,
            predicate: raw.predicate,
            typeName: raw.typeName,
            proto: raw.proto,
            arm: raw.arm,
            params: params,
            captures: captures
        )
    }


    private static func makeMethod(raw: RawMethod) throws -> ImpulseMappingMethod {
        var params: [ImpulseMappingParam] = []
        for rawParam: RawParam in raw.params {
            params.append(try ImpulseMapping.makeParam(raw: rawParam))
        }

        let resultKind: ImpulseMappingResultKind = try ImpulseMapping.makeResultKind(raw: raw.result.kind)
        var resultElement: ImpulseMappingElement? = nil
        if let rawElement: RawElement = raw.result.elem {
            resultElement = try ImpulseMapping.makeElement(raw: rawElement)
        }

        let result: ImpulseMappingResult = ImpulseMappingResult(
            kind: resultKind,
            typeName: raw.result.typeName,
            element: resultElement
        )

        return ImpulseMappingMethod(
            id: raw.id,
            name: raw.name,
            path: raw.path,
            params: params,
            result: result
        )
    }


    private static func makeType(raw: RawType) throws -> ImpulseMappingType {
        var arms: [Int: UInt32] = [:]
        for (key, value): (String, UInt32) in raw.arms ?? [:] {
            guard let arm: Int = Int(key) else {
                throw ImpulseMappingError.invalidArm(key)
            }
            arms[arm] = value
        }

        return ImpulseMappingType(
            name: raw.name,
            proto: raw.proto,
            polymorphic: raw.polymorphic ?? false,
            arms: arms
        )
    }
}


fileprivate struct RawMapping: Decodable {
    let layer: Int
    let constants: [String: UInt32]
    let wrappers: [String: UInt32]
    let constructors: [RawConstructor]
    let methods: [RawMethod]
    let types: [RawType]
}


fileprivate struct RawConstructor: Decodable {
    let id: UInt32
    let predicate: String
    let typeName: String
    let proto: String?
    let arm: Int?
    let params: [RawParam]
    let capture: [RawCapture]?


    private enum CodingKeys: String, CodingKey {
        case id
        case predicate
        case typeName = "type"
        case proto
        case arm
        case params
        case capture
    }
}


fileprivate struct RawCapture: Decodable {
    let field: Int
    let name: String
}


fileprivate struct RawFlag: Decodable {
    let register: String
    let bit: Int


    init(from decoder: Decoder) throws {
        var container: UnkeyedDecodingContainer = try decoder.unkeyedContainer()
        self.register = try container.decode(String.self)
        self.bit = try container.decode(Int.self)
    }
}


fileprivate struct RawElement: Decodable {
    let kind: String
    let typeName: String?


    private enum CodingKeys: String, CodingKey {
        case kind
        case typeName = "type"
    }
}


fileprivate struct RawParam: Decodable {
    let name: String
    let kind: String
    let typeName: String?
    let field: Int?
    let flag: RawFlag?
    let elem: RawElement?
    let derivedFrom: String?
    let unmapped: Bool?


    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case typeName = "type"
        case field
        case flag
        case elem
        case derivedFrom = "derived_from"
        case unmapped
    }
}


fileprivate struct RawResult: Decodable {
    let kind: String
    let typeName: String?
    let elem: RawElement?


    private enum CodingKeys: String, CodingKey {
        case kind
        case typeName = "type"
        case elem
    }
}


fileprivate struct RawMethod: Decodable {
    let id: UInt32
    let name: String
    let path: String
    let params: [RawParam]
    let result: RawResult


    private enum CodingKeys: String, CodingKey {
        case id
        case name = "method"
        case path
        case params
        case result
    }
}


fileprivate struct RawType: Decodable {
    let name: String
    let proto: String?
    let polymorphic: Bool?
    let arms: [String: UInt32]?
}


#if !SWIFT_PACKAGE
fileprivate final class ImpulseMappingBundleAnchor {
}
#endif
