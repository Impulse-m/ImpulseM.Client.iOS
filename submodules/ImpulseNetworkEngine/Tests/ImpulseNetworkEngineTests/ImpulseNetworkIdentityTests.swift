import XCTest
@testable import ImpulseNetworkEngine

final class ImpulseNetworkIdentityTests: XCTestCase {
    private func wifi(address: [UInt8]) -> ImpulseNetworkInterface {
        return ImpulseNetworkInterface(name: "en0", address: address, netmask: [255, 255, 255, 0])
    }

    func testVpnOnlyHasNoFingerprint() {
        let interfaces: [ImpulseNetworkInterface] = [ImpulseNetworkInterface(name: "utun0", address: [10, 8, 0, 2], netmask: [255, 255, 255, 255])]
        XCTAssertNil(ImpulseNetworkIdentity.fingerprint(interfaces: interfaces, routers: []))
    }

    func testHostAddressDoesNotChangeTheNetwork() {
        let first: String? = ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [192, 168, 1, 23])], routers: [])
        let second: String? = ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [192, 168, 1, 77])], routers: [])
        XCTAssertEqual(first, "en0 192.168.1.0/24")
        XCTAssertEqual(first, second)
    }

    func testAnotherNetworkChangesTheFingerprint() {
        let home: String? = ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [192, 168, 1, 23])], routers: [])
        let office: String? = ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [10, 0, 4, 23])], routers: [])
        XCTAssertNotEqual(home, office)
    }

    func testCellularIsOneNetworkWhateverItsAddress() {
        let first: [ImpulseNetworkInterface] = [ImpulseNetworkInterface(name: "pdp_ip0", address: [10, 0, 0, 5], netmask: [255, 255, 255, 255])]
        let second: [ImpulseNetworkInterface] = [ImpulseNetworkInterface(name: "pdp_ip0", address: [10, 0, 9, 80], netmask: [255, 255, 255, 255])]
        XCTAssertEqual(ImpulseNetworkIdentity.fingerprint(interfaces: first, routers: []), "cellular")
        XCTAssertEqual(ImpulseNetworkIdentity.fingerprint(interfaces: second, routers: []), "cellular")
    }

    func testLinkLocalIPv6IsIgnored() {
        var address: [UInt8] = [0xfe, 0x80]
        address.append(contentsOf: [UInt8](repeating: 0, count: 14))
        let interfaces: [ImpulseNetworkInterface] = [ImpulseNetworkInterface(name: "en0", address: address, netmask: [])]
        XCTAssertNil(ImpulseNetworkIdentity.fingerprint(interfaces: interfaces, routers: []))
    }

    func testGlobalIPv6UsesItsSixtyFourBitPrefix() {
        var address: [UInt8] = [0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x01]
        address.append(contentsOf: [UInt8](repeating: 0x77, count: 8))
        let interfaces: [ImpulseNetworkInterface] = [ImpulseNetworkInterface(name: "en0", address: address, netmask: [])]
        XCTAssertEqual(ImpulseNetworkIdentity.fingerprint(interfaces: interfaces, routers: []), "en0 20010db800000001/64")
    }

    func testRouterOfAnActiveServiceJoinsTheFingerprint() {
        let routers: [ImpulseNetworkRouter] = [ImpulseNetworkRouter(interface: "en0", address: "192.168.1.1")]
        XCTAssertEqual(ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [192, 168, 1, 23])], routers: routers), "en0 192.168.1.0/24\nrouter en0 192.168.1.1")
    }

    func testRouterOfAVpnIsLeftOut() {
        let routers: [ImpulseNetworkRouter] = [ImpulseNetworkRouter(interface: "utun0", address: "10.8.0.1")]
        XCTAssertEqual(ImpulseNetworkIdentity.fingerprint(interfaces: [wifi(address: [192, 168, 1, 23])], routers: routers), "en0 192.168.1.0/24")
    }
}
