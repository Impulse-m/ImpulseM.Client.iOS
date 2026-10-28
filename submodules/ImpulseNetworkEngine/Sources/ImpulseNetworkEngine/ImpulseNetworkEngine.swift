import Foundation
import MtProtoKit
import TelegramCore

/// Creates the session `ImpulseNetworkEngine.makeSession` returns, for the given datacenter, role, usage
/// calculation and delegate. The session is the ImpulseTransport network session behind TelegramCore's
/// session interface.
public typealias ImpulseNetworkSessionBuilder = (
    Int,
    NetworkEngineSessionRole,
    MTNetworkUsageCalculationInfo?,
    NetworkEngineSessionDelegate?
) -> NetworkEngineSession

/// What the engine runs besides its sessions while it is active: the connections of the account and the pool that
/// serves the identity. `activate()` starts it and `deactivate()` stops it.
public protocol ImpulseNetworkLifecycle: AnyObject {
    func start()

    func stop()
}

/// The network engine of the ImpulseM backend. It creates the sessions through the injected builder and, while
/// it is active, takes over the key and authorization transfers of MTContext, which go nowhere over MtProtoKit's
/// connections in that case.
public final class ImpulseNetworkEngine: NetworkEngine {
    public let kind: NetworkEngineKind = .impulse

    private let context: MTContext
    private let sessionBuilder: ImpulseNetworkSessionBuilder
    private let actions: ImpulseNoNetworkActions
    private let lifecycle: ImpulseNetworkLifecycle?

    public init(
        context: MTContext,
        sessionBuilder: @escaping ImpulseNetworkSessionBuilder,
        lifecycle: ImpulseNetworkLifecycle? = nil
    ) {
        self.context = context
        self.sessionBuilder = sessionBuilder
        self.actions = ImpulseNoNetworkActions(context: context)
        self.lifecycle = lifecycle
    }

    public func makeSession(
        datacenterId: Int,
        role: NetworkEngineSessionRole,
        usageCalculationInfo: MTNetworkUsageCalculationInfo?,
        delegate: NetworkEngineSessionDelegate?
    ) -> NetworkEngineSession {
        return self.sessionBuilder(datacenterId, role, usageCalculationInfo, delegate)
    }

    /// The salted name of the network the device is on, hex, without any address.
    public func networkIdentity() -> String? {
        let key: Data = ImpulseNetworkIdentity.currentKey()
        if key.isEmpty {
            return nil
        }
        return key.map({ String(format: "%02x", $0) }).joined()
    }

    /// The key and transfer actions of the context go over no network while this engine carries it, and the
    /// lifecycle starts the account's connections.
    public func activate() {
        self.actions.install()
        self.lifecycle?.start()
    }

    /// The factories of the context go back to MTContext's own actions, and the lifecycle stops the connections.
    public func deactivate() {
        self.actions.uninstall()
        self.lifecycle?.stop()
    }
}
