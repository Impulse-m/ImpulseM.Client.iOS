import XCTest
@testable import ImpulseTransport

final class ImpulseTranscoderRoundTripTests: XCTestCase {
    private static let reportLimit: Int = 20
    /// Mirrors the depth limits of ImpulseTlSynth, which decide which nested params the synthesized TL writes.
    private static let synthGuardDepth: Int = 4
    private static let synthHardDepth: Int = 16


    private func report(_ failures: [String]) -> String {
        return failures.prefix(ImpulseTranscoderRoundTripTests.reportLimit).joined(separator: "\n")
    }


    /// Predicts whether the transcoder rejects the TL that ImpulseTlSynth writes for these params.
    /// The transcoder throws encodeFailed for an unmapped param that is not behind a flag, because such a param is
    /// always present on the wire. An unmapped flagged param is never set by the synth, so it does not throw.
    private func expectsUnmappedEncodeFailure(
        params: [ImpulseMappingParam],
        allFlags: Bool,
        synth: ImpulseTlSynth,
        depth: Int
    ) -> Bool {
        for param: ImpulseMappingParam in params {
            if param.kind == .flags || param.derivedFrom != nil {
                continue
            }
            if param.flag != nil && !allFlags {
                continue
            }
            if param.unmapped {
                if param.flag == nil {
                    return true
                }
                continue
            }
            if param.flag != nil, let referenced: String = referencedTypeName(param: param), synth.simplestConstructor(typeName: referenced) == nil {
                continue
            }
            if param.kind == .vector {
                guard depth < ImpulseTranscoderRoundTripTests.synthGuardDepth else {
                    continue
                }
                if let element: ImpulseMappingElement = param.element, element.kind == .object, let typeName: String = element.typeName {
                    if expectsUnmappedEncodeFailure(object: typeName, allFlags: allFlags, synth: synth, depth: depth) {
                        return true
                    }
                }
                continue
            }
            if param.kind == .object, let typeName: String = param.typeName {
                if expectsUnmappedEncodeFailure(object: typeName, allFlags: allFlags, synth: synth, depth: depth) {
                    return true
                }
            }
        }
        return false
    }


    private func expectsUnmappedEncodeFailure(
        object typeName: String,
        allFlags: Bool,
        synth: ImpulseTlSynth,
        depth: Int
    ) -> Bool {
        guard depth <= ImpulseTranscoderRoundTripTests.synthHardDepth else {
            return false
        }
        guard let constructor: ImpulseMappingConstructor = synth.simplestConstructor(typeName: typeName) else {
            return false
        }
        let nestedFlags: Bool = depth >= ImpulseTranscoderRoundTripTests.synthGuardDepth ? false : allFlags
        return expectsUnmappedEncodeFailure(
            params: constructor.params,
            allFlags: nestedFlags,
            synth: synth,
            depth: depth + 1
        )
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


    func testEveryMappedConstructorRoundTrips() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let synth: ImpulseTlSynth = ImpulseTlSynth(mapping: mapping)
        var failures: [String] = []
        var checked: Int = 0

        for constructor: ImpulseMappingConstructor in mapping.constructors where constructor.proto != nil {
            for allFlags: Bool in [true, false] {
                checked += 1
                let expectsFailure: Bool = expectsUnmappedEncodeFailure(
                    params: constructor.params,
                    allFlags: allFlags,
                    synth: synth,
                    depth: 0
                )
                do {
                    let tl: [UInt8] = try synth.constructorTl(constructor: constructor, allFlags: allFlags)
                    if expectsFailure {
                        do {
                            _ = try transcoder.tlObjectToProto(typeName: constructor.typeName, tl: tl)
                            failures.append("\(constructor.predicate) allFlags=\(allFlags): encoded although a param is unmapped")
                        } catch let error as ImpulseTranscodeError {
                            if case .encodeFailed = error {
                                continue
                            }
                            failures.append("\(constructor.predicate) allFlags=\(allFlags): \(error)")
                        }
                        continue
                    }
                    let proto: [UInt8] = try transcoder.tlObjectToProto(typeName: constructor.typeName, tl: tl)
                    let back: [UInt8] = try transcoder.protoToTlObject(
                        typeName: constructor.typeName,
                        proto: proto,
                        capture: nil
                    )
                    if back != tl {
                        failures.append("\(constructor.predicate) allFlags=\(allFlags): TL differs after round trip")
                    }
                } catch {
                    failures.append("\(constructor.predicate) allFlags=\(allFlags): \(error)")
                }
            }
        }

        XCTAssertGreaterThanOrEqual(checked, 1651 * 2)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }


    func testEveryUnmappedConstructorFailsToEncode() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        var failures: [String] = []

        for constructor: ImpulseMappingConstructor in mapping.constructors where constructor.proto == nil {
            var writer: ImpulseTlWriter = ImpulseTlWriter()
            writer.writeInt32(value: Int32(bitPattern: constructor.id))
            do {
                _ = try transcoder.tlObjectToProto(typeName: constructor.typeName, tl: writer.toByteArray())
                failures.append("\(constructor.predicate) encoded although unmapped")
            } catch let error as ImpulseTranscodeError {
                if case .encodeFailed = error {
                    continue
                }
                failures.append("\(constructor.predicate): \(error)")
            } catch {
                failures.append("\(constructor.predicate): \(error)")
            }
        }

        XCTAssertTrue(failures.isEmpty, report(failures))
    }


    func testEveryMethodRequestRoundTrips() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let synth: ImpulseTlSynth = ImpulseTlSynth(mapping: mapping)
        var failures: [String] = []
        var checked: Int = 0

        for method: ImpulseMappingMethod in mapping.methods {
            for allFlags: Bool in [true, false] {
                checked += 1
                let expectsFailure: Bool = expectsUnmappedEncodeFailure(
                    params: method.params,
                    allFlags: allFlags,
                    synth: synth,
                    depth: 0
                )
                do {
                    let tl: [UInt8] = try synth.methodTl(method: method, allFlags: allFlags)
                    if expectsFailure {
                        do {
                            _ = try transcoder.encodeRequest(tl: tl)
                            failures.append("\(method.name) allFlags=\(allFlags): encoded although a param is unmapped")
                        } catch let error as ImpulseTranscodeError {
                            if case .encodeFailed = error {
                                continue
                            }
                            failures.append("\(method.name) allFlags=\(allFlags): \(error)")
                        }
                        continue
                    }
                    let request: ImpulseEncodedRequest = try transcoder.encodeRequest(tl: tl)
                    if request.methodId != method.id || request.path != method.path {
                        failures.append("\(method.name) allFlags=\(allFlags): wrong method or path")
                        continue
                    }
                    let back: [UInt8] = try transcoder.decodeRequest(methodId: method.id, proto: request.proto)
                    if back != tl {
                        failures.append("\(method.name) allFlags=\(allFlags): TL differs after round trip")
                    }
                } catch {
                    failures.append("\(method.name) allFlags=\(allFlags): \(error)")
                }
            }
        }

        XCTAssertGreaterThanOrEqual(checked, 801 * 2)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }


    func testEveryObjectResultDecodes() throws {
        let mapping: ImpulseMapping = try ImpulseMapping.loadBundled()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: mapping)
        let synth: ImpulseTlSynth = ImpulseTlSynth(mapping: mapping)
        var failures: [String] = []
        var checked: Int = 0

        for method: ImpulseMappingMethod in mapping.methods where method.result.kind == .object {
            guard let resultType: String = method.result.typeName else {
                failures.append("\(method.name): object result has no type")
                continue
            }
            guard let constructor: ImpulseMappingConstructor = synth.simplestConstructor(typeName: resultType) else {
                failures.append("\(method.name): no mapped constructor for \(resultType)")
                continue
            }
            for allFlags: Bool in [true, false] {
                checked += 1
                do {
                    let tl: [UInt8] = try synth.constructorTl(constructor: constructor, allFlags: allFlags)
                    let proto: [UInt8] = try transcoder.tlObjectToProto(typeName: resultType, tl: tl)
                    let back: [UInt8] = try transcoder.decodeResult(methodId: method.id, proto: proto, capture: nil)
                    if back != tl {
                        failures.append("\(method.name) result \(resultType) allFlags=\(allFlags): TL differs")
                    }
                } catch {
                    failures.append("\(method.name) result \(resultType) allFlags=\(allFlags): \(error)")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0)
        XCTAssertTrue(failures.isEmpty, report(failures))
    }
}
