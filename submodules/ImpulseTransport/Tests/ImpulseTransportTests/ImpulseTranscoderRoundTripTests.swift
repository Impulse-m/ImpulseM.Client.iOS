import XCTest
@testable import ImpulseTransport

final class ImpulseTranscoderRoundTripTests: XCTestCase {
    private static let reportLimit: Int = 20


    private func report(_ failures: [String]) -> String {
        return failures.prefix(ImpulseTranscoderRoundTripTests.reportLimit).joined(separator: "\n")
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
                do {
                    let tl: [UInt8] = try synth.constructorTl(constructor: constructor, allFlags: allFlags)
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
        XCTAssertTrue(failures.isEmpty, report(failures))
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
                do {
                    let tl: [UInt8] = try synth.methodTl(method: method, allFlags: allFlags)
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
        XCTAssertTrue(failures.isEmpty, report(failures))
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
