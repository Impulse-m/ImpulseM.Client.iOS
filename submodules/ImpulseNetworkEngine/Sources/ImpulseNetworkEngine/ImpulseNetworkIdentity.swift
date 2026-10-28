import Foundation
import MtProtoKit
#if os(macOS)
import SystemConfiguration
#endif

/// An IPv4 or IPv6 address of an active interface, as the system reports it.
struct ImpulseNetworkInterface: Equatable {
    var name: String
    /// 4 bytes for IPv4, 16 bytes for IPv6.
    var address: [UInt8]
    /// 4 bytes for IPv4; empty for IPv6.
    var netmask: [UInt8]
}

/// The router of an active network service, as the system configuration reports it.
struct ImpulseNetworkRouter: Equatable {
    var interface: String
    var address: String
}

/// The salted name of the network the device is on. The interfaces and routers are hashed with a per-install
/// salt, so the name carries no address; the same network gives the same name, a different one a different name.
enum ImpulseNetworkIdentity {
    private static let saltKey: String = "impulsem.networkIdentity.salt.v1"
    private static let ignoredInterfacePrefixes: [String] = ["utun", "ipsec", "ppp", "awdl", "llw", "gif", "stf", "anpi", "ap", "bridge", "vmnet", "vnic", "vboxnet", "feth", "lo"]
    private static let cellularInterfacePrefix: String = "pdp_ip"

    /// The hashed name, or empty when nothing identifies the network.
    static func currentKey() -> Data {
        guard let fingerprint = ImpulseNetworkIdentity.fingerprint(interfaces: ImpulseNetworkIdentity.interfaces(), routers: ImpulseNetworkIdentity.routers()), let salt = ImpulseNetworkIdentity.salt() else {
            return Data()
        }
        var data: Data = salt
        data.append(Data(fingerprint.utf8))
        return MTSha256(data).prefix(16)
    }

    /// The text that identifies the network, or nil when nothing does. Interfaces that say nothing about the
    /// network (VPN tunnels, peer-to-peer and virtual links) are left out, and so is a cellular interface's
    /// address, which changes with every attach.
    static func fingerprint(interfaces: [ImpulseNetworkInterface], routers: [ImpulseNetworkRouter]) -> String? {
        var parts: [String] = []
        var cellular: Bool = false
        for interface in interfaces {
            if ImpulseNetworkIdentity.ignoresInterface(interface.name) {
                continue
            }
            if interface.name.hasPrefix(ImpulseNetworkIdentity.cellularInterfacePrefix) {
                cellular = true
                continue
            }
            if interface.address.count == 4 && interface.netmask.count == 4 {
                if interface.address[0] == 169 && interface.address[1] == 254 {
                    continue
                }
                let network: [UInt8] = zip(interface.address, interface.netmask).map({ $0 & $1 })
                let prefix: Int = interface.netmask.reduce(0, { $0 + $1.nonzeroBitCount })
                parts.append("\(interface.name) \(network.map(String.init).joined(separator: "."))/\(prefix)")
            } else if interface.address.count == 16 {
                let global: Bool = interface.address[0] & 0xe0 == 0x20
                let uniqueLocal: Bool = interface.address[0] & 0xfe == 0xfc
                if !global && !uniqueLocal {
                    continue
                }
                parts.append("\(interface.name) \(interface.address.prefix(8).map({ String(format: "%02x", $0) }).joined())/64")
            }
        }
        if parts.isEmpty {
            return cellular ? "cellular" : nil
        }
        for router in routers where ImpulseNetworkIdentity.routerCounts(router) {
            parts.append("router \(router.interface) \(router.address)")
        }
        return Array(Set(parts)).sorted().joined(separator: "\n")
    }

    static func ignoresInterface(_ name: String) -> Bool {
        return ImpulseNetworkIdentity.ignoredInterfacePrefixes.contains(where: { name.hasPrefix($0) })
    }

    /// Whether a service's router goes into the fingerprint: not on a VPN, virtual or cellular interface.
    static func routerCounts(_ router: ImpulseNetworkRouter) -> Bool {
        return !router.address.isEmpty && !ImpulseNetworkIdentity.ignoresInterface(router.interface) && !router.interface.hasPrefix(ImpulseNetworkIdentity.cellularInterfacePrefix)
    }

    private static func salt() -> Data? {
        if let salt = UserDefaults.standard.data(forKey: ImpulseNetworkIdentity.saltKey), salt.count == 16 {
            return salt
        }
        var bytes: [UInt8] = []
        for _ in 0 ..< 16 {
            bytes.append(UInt8.random(in: 0 ... 255))
        }
        let salt: Data = Data(bytes)
        UserDefaults.standard.set(salt, forKey: ImpulseNetworkIdentity.saltKey)
        return salt
    }

    private static func interfaces() -> [ImpulseNetworkInterface] {
        var result: [ImpulseNetworkInterface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else {
            return result
        }
        defer {
            freeifaddrs(list)
        }
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let item = cursor {
            cursor = item.pointee.ifa_next
            let flags: Int32 = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, let address = item.pointee.ifa_addr, let netmask = item.pointee.ifa_netmask else {
                continue
            }
            let name: String = String(cString: item.pointee.ifa_name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let addressBytes: [UInt8] = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { ImpulseNetworkIdentity.bytes(of: $0.pointee.sin_addr) })
                let maskBytes: [UInt8] = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { ImpulseNetworkIdentity.bytes(of: $0.pointee.sin_addr) })
                result.append(ImpulseNetworkInterface(name: name, address: addressBytes, netmask: maskBytes))
            case AF_INET6:
                let addressBytes: [UInt8] = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { ImpulseNetworkIdentity.bytes(of: $0.pointee.sin6_addr) })
                result.append(ImpulseNetworkInterface(name: name, address: addressBytes, netmask: []))
            default:
                continue
            }
        }
        return result
    }

    private static func bytes<T>(of value: T) -> [UInt8] {
        var value: T = value
        return withUnsafeBytes(of: &value, { Array($0) })
    }

    private static func routers() -> [ImpulseNetworkRouter] {
        return ImpulseNetworkIdentity.serviceRouters().map({ service -> ImpulseNetworkRouter in
            if let hardware = service.hardware {
                return ImpulseNetworkRouter(interface: service.interface, address: "\(service.router) \(hardware)")
            }
            return ImpulseNetworkRouter(interface: service.interface, address: service.router)
        })
    }

    private static func serviceRouters() -> [(interface: String, router: String, hardware: String?)] {
        #if os(macOS)
        guard let store = SCDynamicStoreCreate(nil, "ImpulseM" as CFString, nil, nil), let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else {
            return []
        }
        return keys.compactMap({ key -> (interface: String, router: String, hardware: String?)? in
            guard let service = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any], let interface = service["InterfaceName"] as? String, let router = service["Router"] as? String else {
                return nil
            }
            let hardware: String? = (service["ARPResolvedIPAddress"] as? String) == router ? service["ARPResolvedHardwareAddress"] as? String : nil
            return (interface: interface, router: router, hardware: hardware)
        })
        #else
        return []
        #endif
    }
}
