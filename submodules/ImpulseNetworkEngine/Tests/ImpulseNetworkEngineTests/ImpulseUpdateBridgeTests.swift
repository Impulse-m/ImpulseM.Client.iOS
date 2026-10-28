import Foundation
import XCTest
import MtProtoKit
import TelegramCore
import ImpulseTransport
@testable import ImpulseNetworkEngine


private final class BridgeSinkRecorder: NetworkEngineUpdateSink {
    private(set) var resets: Int = 0
    private(set) var messages: [String] = []


    func networkSessionDidReset() {
        self.resets += 1
    }


    func networkSessionDidReceive(message: Any) {
        if let text: String = message as? String {
            self.messages.append(text)
        }
    }
}


private final class BridgeOptionRecorder {
    private(set) var batches: [[ImpulseDcUpdateOption]] = []


    func record(_ options: [ImpulseDcUpdateOption]) {
        self.batches.append(options)
    }
}


private final class BridgeCounter {
    private(set) var count: Int = 0


    func increment() {
        self.count += 1
    }
}


private let bridgeVectorId: UInt32 = 0x1cb5c415
private let bridgeMediaOnlyFlag: Int32 = 1 << 1
private let bridgeCdnFlag: Int32 = 1 << 3


private func littleEndian(_ value: UInt32) -> [UInt8] {
    return [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}


private func int32Bytes(_ value: Int32) -> [UInt8] {
    return littleEndian(UInt32(bitPattern: value))
}


private func tlStringBytes(_ text: String) -> [UInt8] {
    let bytes: [UInt8] = Array(text.utf8)
    var result: [UInt8] = [UInt8(bytes.count)]
    result += bytes
    while result.count % 4 != 0 {
        result.append(0)
    }
    return result
}


/// An `updateShort` that carries one `updateDcOptions` with one `dcOption`.
private func updateShortWithDcOption(
    id: Int32,
    ipAddress: String,
    port: Int32,
    flags: Int32
) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes += littleEndian(ImpulseDcOptionsUpdate.updateShortId)
    bytes += littleEndian(ImpulseDcOptionsUpdate.updateDcOptionsId)
    bytes += littleEndian(bridgeVectorId)
    bytes += int32Bytes(1)
    bytes += littleEndian(ImpulseDcOptionsUpdate.dcOptionId)
    bytes += int32Bytes(flags)
    bytes += int32Bytes(id)
    bytes += tlStringBytes(ipAddress)
    bytes += int32Bytes(port)
    bytes += int32Bytes(1700000000)
    return bytes
}


final class ImpulseUpdateBridgeTests: XCTestCase {
    func testResetIsHandedToEverySink() {
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                return nil
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
            }
        )
        let first: BridgeSinkRecorder = BridgeSinkRecorder()
        let second: BridgeSinkRecorder = BridgeSinkRecorder()
        bridge.addSink(first)
        bridge.addSink(second)

        bridge.networkSessionDidReset()

        XCTAssertEqual(first.resets, 1)
        XCTAssertEqual(second.resets, 1)
    }


    func testParsedMessagesAreHandedOverInReceiveOrder() {
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                return "message-\(data.count)"
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
                XCTFail("A publication that is not updateDcOptions must not apply DC options")
            }
        )
        let sink: BridgeSinkRecorder = BridgeSinkRecorder()
        bridge.addSink(sink)

        bridge.networkSessionDidReceive(tl: [1, 2, 3])
        bridge.networkSessionDidReceive(tl: [1, 2, 3, 4, 5])

        XCTAssertEqual(sink.messages, ["message-3", "message-5"])
    }


    func testMessageThatDoesNotParseIsNotHandedOver() {
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                return nil
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
            }
        )
        let sink: BridgeSinkRecorder = BridgeSinkRecorder()
        bridge.addSink(sink)

        bridge.networkSessionDidReceive(tl: [1, 2, 3, 4])

        XCTAssertTrue(sink.messages.isEmpty)
    }


    func testUpdateDcOptionsIsAppliedAndNotHandedOver() {
        let applied: BridgeOptionRecorder = BridgeOptionRecorder()
        let parsed: BridgeCounter = BridgeCounter()
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                parsed.increment()
                return "message"
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
                applied.record(options)
            }
        )
        let sink: BridgeSinkRecorder = BridgeSinkRecorder()
        bridge.addSink(sink)

        bridge.networkSessionDidReceive(tl: updateShortWithDcOption(
            id: 2,
            ipAddress: "10.1.2.3",
            port: 443,
            flags: bridgeMediaOnlyFlag
        ))

        XCTAssertEqual(applied.batches.count, 1)
        XCTAssertEqual(applied.batches.first?.first?.id, 2)
        XCTAssertEqual(applied.batches.first?.first?.ipAddress, "10.1.2.3")
        XCTAssertEqual(parsed.count, 0)
        XCTAssertTrue(sink.messages.isEmpty)
    }


    func testUpdateDcOptionsSetsTheAddressSetOfTheContext() {
        let context: MTContext = impulseMakeContext()
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(context: context)

        bridge.networkSessionDidReceive(tl: updateShortWithDcOption(
            id: 2,
            ipAddress: "10.1.2.3",
            port: 443,
            flags: bridgeMediaOnlyFlag | bridgeCdnFlag
        ))
        impulseFlushContextQueue()

        let addresses: [MTDatacenterAddress]? = context.addressSetForDatacenter(withId: 2).addressList as? [MTDatacenterAddress]
        XCTAssertEqual(addresses?.count, 1)
        XCTAssertEqual(addresses?.first?.ip, "10.1.2.3")
        XCTAssertEqual(addresses?.first?.port, 443)
        XCTAssertEqual(addresses?.first?.preferForMedia, true)
        XCTAssertEqual(addresses?.first?.cdn, true)
    }


    func testAddressListsGroupOptionsByDatacenter() {
        let options: [ImpulseDcUpdateOption] = [
            ImpulseDcUpdateOption(
                id: 1,
                ipAddress: "10.0.0.1",
                port: 443,
                mediaOnly: false,
                tcpOnly: false,
                cdn: false,
                staticAddress: false,
                secret: nil
            ),
            ImpulseDcUpdateOption(
                id: 1,
                ipAddress: "10.0.0.2",
                port: 8443,
                mediaOnly: true,
                tcpOnly: true,
                cdn: false,
                staticAddress: false,
                secret: nil
            ),
            ImpulseDcUpdateOption(
                id: 2,
                ipAddress: "10.0.0.3",
                port: 443,
                mediaOnly: false,
                tcpOnly: false,
                cdn: true,
                staticAddress: true,
                secret: [1, 2, 3]
            ),
        ]

        let lists: [Int32: [MTDatacenterAddress]] = ImpulseDcOptionsApplier.addressLists(options: options)

        XCTAssertEqual(lists.keys.sorted(), [1, 2])
        XCTAssertEqual(lists[1]?.compactMap { (address: MTDatacenterAddress) -> String? in
            return address.ip
        }, ["10.0.0.1", "10.0.0.2"])
        XCTAssertEqual(lists[1]?.last?.port, 8443)
        XCTAssertEqual(lists[1]?.last?.restrictToTcp, true)
        XCTAssertEqual(lists[2]?.first?.cdn, true)
        XCTAssertEqual(lists[2]?.first?.preferForProxy, true)
        XCTAssertEqual(lists[2]?.first?.secret, Data([1, 2, 3]))
    }
}
