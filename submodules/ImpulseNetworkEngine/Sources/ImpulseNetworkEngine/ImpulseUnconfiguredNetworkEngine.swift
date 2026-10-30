import Foundation
import MtProtoKit
import TelegramCore

/// The engine of an ImpulseM network whose RPC base URL is not configured, as in a local or test build without the build
/// variable. Its sessions never connect and never contact any host: every request fails at once with `notConfiguredError`.
/// It is a valid `NetworkEngine`, so the network starts and the app stays not connected. While it carries the context,
/// MTContext's key and transfer actions make nothing over MtProtoKit's connections either.
final class ImpulseUnconfiguredNetworkEngine: NetworkEngine {
    /// The error every request of the engine fails with.
    static let notConfiguredError: MTRpcError = MTRpcError(errorCode: 500, errorDescription: "IMPULSE_NOT_CONFIGURED")

    let kind: NetworkEngineKind = .impulse

    private let actions: ImpulseNoNetworkActions


    init(context: MTContext) {
        self.actions = ImpulseNoNetworkActions(context: context)
    }


    func makeSession(
        datacenterId: Int,
        role: NetworkEngineSessionRole,
        usageCalculationInfo: MTNetworkUsageCalculationInfo?,
        delegate: NetworkEngineSessionDelegate?
    ) -> NetworkEngineSession {
        return ImpulseUnconfiguredNetworkSession(datacenterId: datacenterId)
    }


    /// The key and transfer actions of the context go over no network while this engine carries it.
    func activate() {
        self.actions.install()
    }


    /// The factories of the context go back to MTContext's own actions.
    func deactivate() {
        self.actions.uninstall()
    }
}
