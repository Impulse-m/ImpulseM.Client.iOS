import Foundation


/// One DC option of an `updateDcOptions` update, with its flags read into named values.
public struct ImpulseDcUpdateOption: Equatable, Sendable {
    /// The datacenter the address belongs to.
    public let id: Int32
    /// The IPv4 or IPv6 address of the option, as the server sent it.
    public let ipAddress: String
    /// The port of the option.
    public let port: Int
    /// The option serves media only.
    public let mediaOnly: Bool
    /// The option is reached over TCP only.
    public let tcpOnly: Bool
    /// The option is a CDN address.
    public let cdn: Bool
    /// The option is a static address, for a proxy.
    public let staticAddress: Bool
    /// The MTProto secret of the option, when it has one.
    public let secret: [UInt8]?


    public init(
        id: Int32,
        ipAddress: String,
        port: Int,
        mediaOnly: Bool,
        tcpOnly: Bool,
        cdn: Bool,
        staticAddress: Bool,
        secret: [UInt8]?
    ) {
        self.id = id
        self.ipAddress = ipAddress
        self.port = port
        self.mediaOnly = mediaOnly
        self.tcpOnly = tcpOnly
        self.cdn = cdn
        self.staticAddress = staticAddress
        self.secret = secret
    }
}


/// Why a DC option list did not decode. It never leaves this file: `ImpulseDcOptionsUpdate.dcOptions` answers nil.
private enum ImpulseDcOptionsError: Error {
    case malformed
}


/// Reads the DC options of a realtime publication that carries `updateDcOptions` (`system:config`).
public enum ImpulseDcOptionsUpdate {
    /// The constructor of `updateDcOptions`.
    public static let updateDcOptionsId: UInt32 = 0x8e5e9873
    /// The constructor of one `dcOption`.
    public static let dcOptionId: UInt32 = 0x18b7a10d
    /// The constructor of `updateShort`, which carries one update.
    public static let updateShortId: UInt32 = 0x78d4dec1
    /// The constructor of the `updates` container, which carries a vector of updates.
    public static let updatesId: UInt32 = 0x74ae4240

    private static let mediaOnlyBit: Int32 = 1 << 1
    private static let tcpOnlyBit: Int32 = 1 << 2
    private static let cdnBit: Int32 = 1 << 3
    private static let staticBit: Int32 = 1 << 4
    private static let secretBit: Int32 = 1 << 10


    /// The DC options of a publication that is exactly one `updateDcOptions`: a bare update, an `updateShort`, or an
    /// `updates` container that holds one update. Nil for any other publication and for one that does not decode.
    public static func dcOptions(tl: [UInt8]) -> [ImpulseDcUpdateOption]? {
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            let head: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)

            if head == ImpulseDcOptionsUpdate.updateDcOptionsId {
                return try ImpulseDcOptionsUpdate.readDcOptions(reader: &reader)
            }

            if head == ImpulseDcOptionsUpdate.updateShortId {
                let update: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)
                guard update == ImpulseDcOptionsUpdate.updateDcOptionsId else {
                    return nil
                }
                return try ImpulseDcOptionsUpdate.readDcOptions(reader: &reader)
            }

            if head == ImpulseDcOptionsUpdate.updatesId {
                let vector: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)
                guard vector == ImpulseTlConstants.vector else {
                    return nil
                }
                let count: Int32 = try reader.readInt32()
                guard count == 1 else {
                    return nil
                }
                let update: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)
                guard update == ImpulseDcOptionsUpdate.updateDcOptionsId else {
                    return nil
                }
                return try ImpulseDcOptionsUpdate.readDcOptions(reader: &reader)
            }

            return nil
        } catch {
            return nil
        }
    }


    private static func readWord(reader: inout ImpulseTlReader) throws -> UInt32 {
        let bits: Int32 = try reader.readInt32()
        return UInt32(bitPattern: bits)
    }


    /// Reads the vector of `dcOption` that follows the constructor of `updateDcOptions`.
    private static func readDcOptions(reader: inout ImpulseTlReader) throws -> [ImpulseDcUpdateOption] {
        let vector: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)
        guard vector == ImpulseTlConstants.vector else {
            throw ImpulseDcOptionsError.malformed
        }

        let count: Int32 = try reader.readInt32()
        guard count >= 0 else {
            throw ImpulseDcOptionsError.malformed
        }

        var options: [ImpulseDcUpdateOption] = []
        var index: Int32 = 0
        while index < count {
            options.append(try ImpulseDcOptionsUpdate.readDcOption(reader: &reader))
            index += 1
        }
        return options
    }


    /// Reads `dcOption#18b7a10d flags:# ipv6:flags.0?true media_only:flags.1?true tcpo_only:flags.2?true cdn:flags.3?true
    /// static:flags.4?true this_port_only:flags.5?true id:int ip_address:string port:int secret:flags.10?bytes`.
    private static func readDcOption(reader: inout ImpulseTlReader) throws -> ImpulseDcUpdateOption {
        let constructor: UInt32 = try ImpulseDcOptionsUpdate.readWord(reader: &reader)
        guard constructor == ImpulseDcOptionsUpdate.dcOptionId else {
            throw ImpulseDcOptionsError.malformed
        }

        let flags: Int32 = try reader.readInt32()
        let id: Int32 = try reader.readInt32()
        let ipAddress: String = try reader.readString()
        let port: Int32 = try reader.readInt32()

        var secret: [UInt8]? = nil
        if (flags & ImpulseDcOptionsUpdate.secretBit) != 0 {
            secret = try reader.readBytes()
        }

        return ImpulseDcUpdateOption(
            id: id,
            ipAddress: ipAddress,
            port: Int(port),
            mediaOnly: (flags & ImpulseDcOptionsUpdate.mediaOnlyBit) != 0,
            tcpOnly: (flags & ImpulseDcOptionsUpdate.tcpOnlyBit) != 0,
            cdn: (flags & ImpulseDcOptionsUpdate.cdnBit) != 0,
            staticAddress: (flags & ImpulseDcOptionsUpdate.staticBit) != 0,
            secret: secret
        )
    }
}
