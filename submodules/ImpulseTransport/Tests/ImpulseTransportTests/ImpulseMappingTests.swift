import XCTest
@testable import ImpulseTransport


final class ImpulseMappingTests: XCTestCase {
    private let mappedConstructorCount: Int = 1651
    private let unmappedConstructorCount: Int = 69
    private let mappedMethodCount: Int = 801


    private func loadMapping() throws -> ImpulseMapping {
        return try ImpulseMapping.loadBundled()
    }


    private func minimalDocument(
        constructors: String,
        methods: String
    ) -> Data {
        let document: String = """
        {
          "layer": 232,
          "constants": {"boolFalse": 3162085175, "boolTrue": 2574415285, "vector": 481674261},
          "wrappers": {"initConnection": 3251461801},
          "constructors": [\(constructors)],
          "methods": [\(methods)],
          "types": [{"arms": {"1": 10}, "name": "Sample", "polymorphic": true, "proto": "Sample"}]
        }
        """
        return Data(document.utf8)
    }


    func testLayerIs232() throws {
        let mapping: ImpulseMapping = try loadMapping()
        XCTAssertEqual(mapping.layer, 232)
    }


    func testConstructorCountIs1720() throws {
        let mapping: ImpulseMapping = try loadMapping()
        XCTAssertEqual(mapping.constructors.count, 1720)
    }


    func testMappedMethodCountIs801() throws {
        let mapping: ImpulseMapping = try loadMapping()
        XCTAssertEqual(mapping.methods.count, mappedMethodCount)
    }


    func testUnmappedConstructorsCarryNilProto() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let unmapped: [ImpulseMappingConstructor] = mapping.constructors.filter { (candidate: ImpulseMappingConstructor) -> Bool in
            return candidate.proto == nil
        }
        let mapped: [ImpulseMappingConstructor] = mapping.constructors.filter { (candidate: ImpulseMappingConstructor) -> Bool in
            return candidate.proto != nil
        }
        XCTAssertEqual(unmapped.count, unmappedConstructorCount)
        XCTAssertEqual(mapped.count, mappedConstructorCount)
    }


    func testWrapperIdsAreLiteralContractValues() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let expected: [String: UInt32] = [
            "invokeAfterMsg": ImpulseWrapperIds.invokeAfterMsg,
            "invokeAfterMsgs": ImpulseWrapperIds.invokeAfterMsgs,
            "initConnection": ImpulseWrapperIds.initConnection,
            "invokeWithLayer": ImpulseWrapperIds.invokeWithLayer,
            "invokeWithoutUpdates": ImpulseWrapperIds.invokeWithoutUpdates,
            "invokeWithMessagesRange": ImpulseWrapperIds.invokeWithMessagesRange,
            "invokeWithTakeout": ImpulseWrapperIds.invokeWithTakeout,
            "invokeWithBusinessConnection": ImpulseWrapperIds.invokeWithBusinessConnection,
            "invokeWithGooglePlayIntegrity": ImpulseWrapperIds.invokeWithGooglePlayIntegrity,
            "invokeWithApnsSecret": ImpulseWrapperIds.invokeWithApnsSecret,
            "invokeWithReCaptcha": ImpulseWrapperIds.invokeWithReCaptcha,
        ]

        XCTAssertEqual(expected.count, 11)
        XCTAssertEqual(mapping.wrappers.count, expected.count)
        for (name, id): (String, UInt32) in expected {
            XCTAssertEqual(mapping.wrappers[name], id, name)
        }
    }


    func testWrapperLiteralsMatchContractHex() {
        XCTAssertEqual(ImpulseWrapperIds.initConnection, 0xc1cd5ea9)
        XCTAssertEqual(ImpulseWrapperIds.invokeWithTakeout, 0xaca9fd2e)
        XCTAssertEqual(ImpulseWrapperIds.invokeWithApnsSecret, 0x0dae54f8)
    }


    func testTlConstantsMatchMapping() throws {
        let mapping: ImpulseMapping = try loadMapping()
        XCTAssertEqual(mapping.constants["vector"], ImpulseTlConstants.vector)
        XCTAssertEqual(mapping.constants["boolTrue"], ImpulseTlConstants.boolTrue)
        XCTAssertEqual(mapping.constants["boolFalse"], ImpulseTlConstants.boolFalse)
        XCTAssertEqual(ImpulseTlConstants.vector, 0x1cb5c415)
        XCTAssertEqual(ImpulseTlConstants.boolTrue, 0x997275b5)
        XCTAssertEqual(ImpulseTlConstants.boolFalse, 0xbc799737)
    }


    func testLookupByIdAndName() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let boolTrue: ImpulseMappingConstructor? = mapping.constructor(id: ImpulseTlConstants.boolTrue)
        XCTAssertEqual(boolTrue?.predicate, "boolTrue")
        XCTAssertEqual(boolTrue?.typeName, "Bool")

        let sendCode: ImpulseMappingMethod? = mapping.method(name: "auth.sendCode")
        XCTAssertEqual(sendCode?.id, 2792825935)
        XCTAssertEqual(mapping.method(id: 2792825935)?.name, "auth.sendCode")
        XCTAssertNil(mapping.method(name: "no.such.method"))
    }


    func testParsesMinimalDocumentWithFlagsElementsAndArms() throws {
        let constructors: String = """
        {"arm": 1, "capture": [{"field": 6, "name": "session_token"}], "id": 10, "params": [\
        {"field": 1, "flag": ["flags", 2], "kind": "Bool", "name": "ok"}, \
        {"field": 2, "kind": "vector", "name": "items", "elem": {"kind": "object", "type": "Sample"}}, \
        {"kind": "flags", "name": "flags"}], "predicate": "sample", "proto": "Sample", "type": "Sample"}
        """
        let methods: String = """
        {"id": 20, "method": "sample.call", "params": [], "path": "/v1.sample.Sample/Call", "result": {"kind": "list", "elem": {"kind": "object", "type": "Sample"}}}
        """
        let mapping: ImpulseMapping = try ImpulseMapping.parse(
            data: minimalDocument(constructors: constructors, methods: methods)
        )

        let constructor: ImpulseMappingConstructor? = mapping.constructor(id: 10)
        XCTAssertEqual(constructor?.arm, 1)
        XCTAssertEqual(constructor?.proto, "Sample")
        XCTAssertEqual(constructor?.captures, [ImpulseMappingCapture(field: 6, name: "session_token")])
        XCTAssertEqual(constructor?.params.count, 3)
        XCTAssertEqual(constructor?.params[0].kind, .bool)
        XCTAssertEqual(constructor?.params[0].flag, ImpulseMappingFlag(register: "flags", bit: 2))
        XCTAssertEqual(constructor?.params[1].element, ImpulseMappingElement(kind: .object, typeName: "Sample"))
        XCTAssertEqual(constructor?.params[2].kind, .flags)

        XCTAssertEqual(mapping.constructor(ofType: "Sample", arm: 1)?.id, 10)
        XCTAssertEqual(mapping.constructors(ofType: "Sample").count, 1)

        let method: ImpulseMappingMethod? = mapping.method(name: "sample.call")
        XCTAssertEqual(method?.result.kind, .list)
        XCTAssertEqual(method?.result.element, ImpulseMappingElement(kind: .object, typeName: "Sample"))
    }


    func testUnmappedParamsAreRecorded() throws {
        let mapping: ImpulseMapping = try loadMapping()
        let unmappedParams: [ImpulseMappingParam] = mapping.constructors.flatMap { (candidate: ImpulseMappingConstructor) -> [ImpulseMappingParam] in
            return candidate.params
        }.filter { (param: ImpulseMappingParam) -> Bool in
            return param.unmapped
        }
        XCTAssertEqual(unmappedParams.count, 15)
    }


    func testUnknownParamKindThrows() {
        let constructors: String = """
        {"arm": null, "capture": [], "id": 11, "params": [{"kind": "weird", "name": "x"}], "predicate": "bad", "proto": "Bad", "type": "Bad"}
        """
        let data: Data = minimalDocument(constructors: constructors, methods: "")
        XCTAssertThrowsError(try ImpulseMapping.parse(data: data)) { (error: Error) -> Void in
            XCTAssertEqual(error as? ImpulseMappingError, ImpulseMappingError.unknownParamKind("weird"))
        }
    }


    func testDuplicateConstructorIdThrows() {
        let constructor: String = """
        {"arm": null, "capture": [], "id": 12, "params": [], "predicate": "dup", "proto": "Dup", "type": "Dup"}
        """
        let data: Data = minimalDocument(constructors: constructor + "," + constructor, methods: "")
        XCTAssertThrowsError(try ImpulseMapping.parse(data: data)) { (error: Error) -> Void in
            XCTAssertEqual(error as? ImpulseMappingError, ImpulseMappingError.duplicateConstructorId(12))
        }
    }
}
