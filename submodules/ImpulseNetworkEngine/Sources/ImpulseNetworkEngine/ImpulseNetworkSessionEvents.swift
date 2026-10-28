import Foundation
import ImpulseTransport


/// The delegate and update sink of one transport session. It holds its session weakly and hands the session every
/// event the transport raises.
final class ImpulseNetworkSessionEvents: ImpulseNetworkSessionDelegate, ImpulseUpdateSink {
    weak var owner: ImpulseNetworkEngineSession?


    func networkSessionAuthorizationRequired() {
        self.owner?.handleAuthorizationRequired()
    }


    func networkSessionDidReset() {
        self.owner?.handleReset()
    }


    func networkSessionDidReceive(tl: [UInt8]) {
        self.owner?.handleUpdate(tl: tl)
    }
}
