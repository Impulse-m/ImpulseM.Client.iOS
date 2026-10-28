import Foundation
import MtProtoKit
import ImpulseTransport


/// Applies the DC options of an `updateDcOptions` to the datacenter address sets of a context. Each datacenter the
/// update names takes the addresses listed for it, as the configuration of `help.getConfig` is applied.
enum ImpulseDcOptionsApplier {
    /// The address lists of the options, grouped by datacenter, in the order the server sent them.
    static func addressLists(options: [ImpulseDcUpdateOption]) -> [Int32: [MTDatacenterAddress]] {
        var lists: [Int32: [MTDatacenterAddress]] = [:]
        for option: ImpulseDcUpdateOption in options {
            let address: MTDatacenterAddress = MTDatacenterAddress(
                ip: option.ipAddress,
                port: UInt16(clamping: option.port),
                preferForMedia: option.mediaOnly,
                restrictToTcp: option.tcpOnly,
                cdn: option.cdn,
                preferForProxy: option.staticAddress,
                secret: option.secret.map { (bytes: [UInt8]) -> Data in
                    return Data(bytes)
                }
            )
            lists[option.id, default: []].append(address)
        }
        return lists
    }


    /// Sets the address set of every datacenter the options name. The context's queue runs the update.
    static func apply(
        options: [ImpulseDcUpdateOption],
        to context: MTContext
    ) {
        let lists: [Int32: [MTDatacenterAddress]] = ImpulseDcOptionsApplier.addressLists(options: options)
        context.performBatchUpdates {
            for (id, list) in lists {
                context.updateAddressSetForDatacenter(
                    withId: Int(id),
                    addressSet: MTDatacenterAddressSet(addressList: list),
                    forceUpdateSchemes: false
                )
            }
        }
    }
}
