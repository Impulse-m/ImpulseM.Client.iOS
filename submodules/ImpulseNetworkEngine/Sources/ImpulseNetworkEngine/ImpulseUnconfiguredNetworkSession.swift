import Foundation
import TelegramCore


/// One session of an unconfigured engine. It has no transport: pausing, online state, update sinks and stopping change
/// nothing, and it holds no pending request, so moving its requests completes at once.
final class ImpulseUnconfiguredNetworkSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService


    init(datacenterId: Int) {
        self.datacenterId = datacenterId
        self.requestService = ImpulseUnconfiguredRequestService()
    }


    func setPaused(_ paused: Bool) {
    }


    func setOnline(_ online: Bool) {
    }


    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
    }


    func stop() {
    }


    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        completion()
    }
}
