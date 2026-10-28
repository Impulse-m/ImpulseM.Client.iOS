import Foundation
import TelegramCore
import ImpulseTransport


/// The receiver of what the realtime client delivers. The main session of the account is its implementation.
protocol ImpulseUpdateDelivering: AnyObject {
    /// One realtime update as its TL bytes, with the name of the lane it came on.
    func deliverUpdate(
        tl: [UInt8],
        channel: String
    )

    /// The updates may have been lost: the receiver resynchronizes.
    func deliverReset()
}


extension ImpulseNetworkSession: ImpulseUpdateDelivering {
}


/// Forwards the publications and the differences of the realtime client to the main session. The session is held weakly:
/// the realtime client exists before any session does, and a publication that arrives with no main session is dropped.
final class ImpulseRealtimeForwarder {
    private let lock: NSLock = NSLock()
    private weak var delivery: ImpulseUpdateDelivering?


    init() {
    }


    /// Sets the receiver of the publications, or nil when none receives them.
    func setDelivery(_ delivery: ImpulseUpdateDelivering?) {
        self.lock.lock()
        self.delivery = delivery
        self.lock.unlock()
    }


    /// The receiver now, or nil when none is set.
    func currentDelivery() -> ImpulseUpdateDelivering? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.delivery
    }


    /// Hands one publication to the receiver with the name of its lane, so the update bridge can recognise the system config lane.
    func forward(updates: ImpulseRealtimeUpdates) {
        guard let target: ImpulseUpdateDelivering = self.currentDelivery() else {
            return
        }
        target.deliverUpdate(tl: updates.tl, channel: updates.channel)
    }


    /// A difference the realtime client asks for becomes a reset of the receiver. The reset resynchronizes the account, which
    /// covers the lost position of every lane, so each request has the same effect.
    func forward(difference: ImpulseDifferenceRequest) {
        guard let target: ImpulseUpdateDelivering = self.currentDelivery() else {
            return
        }
        Logger.shared.log("ImpulseNetwork", "A difference was requested: \(difference)")
        target.deliverReset()
    }
}
