import Foundation
import SwiftSignalKit
import MtProtoKit

/// A key action of MTContext that makes no request. It fails at once, so MTContext keeps its own backoff
/// and asks again through whichever factories are installed then. Permanent and temporary keys are not
/// made over the network while this engine carries the context.
final class ImpulseNoNetworkAuthAction: MTDatacenterAuthAction {
    init(
        selector: MTDatacenterAuthInfoSelector,
        isCdn: Bool,
        skipBind: Bool,
        completion: @escaping (MTDatacenterAuthAction, Bool) -> Void
    ) {
        super.init(authKeyInfoSelector: selector, isCdn: isCdn, skipBind: skipBind, completion: { action, success in
            if let action: MTDatacenterAuthAction = action {
                completion(action, success)
            }
        })
    }

    override func execute(_ context: MTContext!, datacenterId: Int) {
        self.fail()
    }
}

/// An authorization transfer of MTContext that makes no request. It reports the failure, which MTContext
/// answers with its backoff.
final class ImpulseNoNetworkTransferAction: MTDatacenterTransferAuthAction {
    override func execute(_ context: MTContext!, masterDatacenterId: Int, destinationDatacenterId: Int, authToken: Any!) {
        self.fail()
    }
}

/// MTContext's key and transfer actions while the ImpulseM engine carries the context's network. They are
/// installed by `ImpulseNetworkEngine.activate()` and removed by `deactivate()`; without them MTContext
/// would make the keys and transfers over MtProtoKit's own connections.
final class ImpulseNoNetworkActions {
    private weak var context: MTContext?
    private let lock: NSLock = NSLock()
    private var installed: Bool = false

    init(context: MTContext) {
        self.context = context
    }

    /// The factories are set on MTContext's queue, as every other write of its actions is. A later
    /// `uninstall` that ran first leaves them unset.
    func install() {
        self.setInstalled(true)
        guard let context = self.context else {
            return
        }
        MTContext.contextQueue().dispatch(onQueue: { [weak context] in
            guard let context = context, self.isInstalled() else {
                return
            }
            context.authActionFactory = { selector, isCdn, skipBind, completion in
                return ImpulseNoNetworkAuthAction(selector: selector, isCdn: isCdn, skipBind: skipBind, completion: completion)
            }
            context.transferAuthActionFactory = {
                return ImpulseNoNetworkTransferAction()
            }
        }, synchronous: false)
    }

    /// The factories are cleared on MTContext's queue, unless `install` ran again by then.
    func uninstall() {
        self.setInstalled(false)
        guard let context = self.context else {
            return
        }
        MTContext.contextQueue().dispatch(onQueue: { [weak context] in
            guard let context = context, !self.isInstalled() else {
                return
            }
            context.authActionFactory = nil
            context.transferAuthActionFactory = nil
        }, synchronous: false)
    }

    private func setInstalled(_ value: Bool) {
        self.lock.lock()
        self.installed = value
        self.lock.unlock()
    }

    private func isInstalled() -> Bool {
        self.lock.lock()
        let value: Bool = self.installed
        self.lock.unlock()
        return value
    }
}
