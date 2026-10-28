import Foundation
import XCTest
@testable import ImpulseTransport


final class ImpulseDcOptionsTests: XCTestCase {
    private let mediaOnlyFlag: Int32 = 1 << 1
    private let cdnFlag: Int32 = 1 << 3
    private let staticFlag: Int32 = 1 << 4
    private let secretFlag: Int32 = 1 << 10


    private func word(_ value: UInt32) -> Int32 {
        return Int32(bitPattern: value)
    }


    private func writeDcOption(
        writer: inout ImpulseTlWriter,
        flags: Int32,
        id: Int32,
        ipAddress: String,
        port: Int32,
        secret: [UInt8]?
    ) throws {
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.dcOptionId))
        writer.writeInt32(value: flags)
        writer.writeInt32(value: id)
        try writer.writeString(value: ipAddress)
        writer.writeInt32(value: port)
        if let secret: [UInt8] = secret {
            try writer.writeBytes(value: secret)
        }
    }


    private func writeDcOptionVector(
        writer: inout ImpulseTlWriter,
        options: [(flags: Int32, id: Int32, ipAddress: String, port: Int32, secret: [UInt8]?)]
    ) throws {
        writer.writeInt32(value: word(ImpulseTlConstants.vector))
        writer.writeInt32(value: Int32(options.count))
        for option: (flags: Int32, id: Int32, ipAddress: String, port: Int32, secret: [UInt8]?) in options {
            try writeDcOption(
                writer: &writer,
                flags: option.flags,
                id: option.id,
                ipAddress: option.ipAddress,
                port: option.port,
                secret: option.secret
            )
        }
    }


    private func updateShortBytes(
        flags: Int32,
        secret: [UInt8]?
    ) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updateShortId))
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updateDcOptionsId))
        try writeDcOptionVector(writer: &writer, options: [(flags: flags, id: 2, ipAddress: "149.154.167.51", port: 443, secret: secret)])
        writer.writeInt32(value: 1700000000)
        return writer.toByteArray()
    }


    func testUpdateShortCarryingOneDcOptionIsRead() throws {
        let tl: [UInt8] = try updateShortBytes(flags: mediaOnlyFlag | cdnFlag, secret: nil)

        let options: [ImpulseDcUpdateOption]? = ImpulseDcOptionsUpdate.dcOptions(tl: tl)

        XCTAssertEqual(options, [
            ImpulseDcUpdateOption(
                id: 2,
                ipAddress: "149.154.167.51",
                port: 443,
                mediaOnly: true,
                tcpOnly: false,
                cdn: true,
                staticAddress: false,
                secret: nil
            ),
        ])
    }


    func testSecretAndStaticFlagsAreRead() throws {
        let secret: [UInt8] = [1, 2, 3]
        let tl: [UInt8] = try updateShortBytes(flags: staticFlag | secretFlag, secret: secret)

        let options: [ImpulseDcUpdateOption]? = ImpulseDcOptionsUpdate.dcOptions(tl: tl)

        XCTAssertEqual(options?.count, 1)
        XCTAssertEqual(options?.first?.staticAddress, true)
        XCTAssertEqual(options?.first?.mediaOnly, false)
        XCTAssertEqual(options?.first?.secret, secret)
    }


    func testBareUpdateWithSeveralOptionsIsRead() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updateDcOptionsId))
        try writeDcOptionVector(writer: &writer, options: [
            (flags: 0, id: 1, ipAddress: "10.0.0.1", port: 443, secret: nil),
            (flags: mediaOnlyFlag, id: 2, ipAddress: "10.0.0.2", port: 8443, secret: nil),
        ])

        let options: [ImpulseDcUpdateOption]? = ImpulseDcOptionsUpdate.dcOptions(tl: writer.toByteArray())

        XCTAssertEqual(options?.map { (option: ImpulseDcUpdateOption) -> Int32 in
            return option.id
        }, [1, 2])
        XCTAssertEqual(options?.last?.port, 8443)
    }


    func testUpdatesContainerWithOneUpdateIsRead() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updatesId))
        writer.writeInt32(value: word(ImpulseTlConstants.vector))
        writer.writeInt32(value: 1)
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updateDcOptionsId))
        try writeDcOptionVector(writer: &writer, options: [(flags: 0, id: 4, ipAddress: "10.0.0.4", port: 443, secret: nil)])
        writer.writeInt32(value: word(ImpulseTlConstants.vector))
        writer.writeInt32(value: 0)

        let options: [ImpulseDcUpdateOption]? = ImpulseDcOptionsUpdate.dcOptions(tl: writer.toByteArray())

        XCTAssertEqual(options?.map { (option: ImpulseDcUpdateOption) -> Int32 in
            return option.id
        }, [4])
    }


    func testUpdatesContainerWithTwoUpdatesIsNotDcOptions() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updatesId))
        writer.writeInt32(value: word(ImpulseTlConstants.vector))
        writer.writeInt32(value: 2)

        XCTAssertNil(ImpulseDcOptionsUpdate.dcOptions(tl: writer.toByteArray()))
    }


    func testAnotherUpdateIsNotDcOptions() throws {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: word(ImpulseDcOptionsUpdate.updateShortId))
        writer.writeInt32(value: 0x12345678)
        writer.writeInt32(value: 0)

        XCTAssertNil(ImpulseDcOptionsUpdate.dcOptions(tl: writer.toByteArray()))
    }


    func testTruncatedUpdateIsNotDcOptions() throws {
        let complete: [UInt8] = try updateShortBytes(flags: mediaOnlyFlag, secret: nil)
        let truncated: [UInt8] = Array(complete[0 ..< complete.count - 6])

        XCTAssertNil(ImpulseDcOptionsUpdate.dcOptions(tl: truncated))
    }


    func testEmptyPublicationIsNotDcOptions() {
        XCTAssertNil(ImpulseDcOptionsUpdate.dcOptions(tl: []))
    }
}
