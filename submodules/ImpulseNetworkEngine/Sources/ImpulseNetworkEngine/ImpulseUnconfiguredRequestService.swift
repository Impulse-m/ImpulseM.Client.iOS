import Foundation
import SwiftSignalKit
import TelegramCore


/// The request scheduler of an unconfigured session. It completes every request at once with
/// `ImpulseUnconfiguredNetworkEngine.notConfiguredError`, without any network. A request cancelled before that is never completed.
final class ImpulseUnconfiguredRequestService: NetworkEngineRequestService {
    /// The cancellation state of one request. Its lock is held across the check and the completion, so a cancel either
    /// precedes the completion, or waits until the completion has returned. No callback runs after a processed cancel.
    private final class Settlement {
        let lock: NSRecursiveLock = NSRecursiveLock()
        var cancelled: Bool = false
    }


    private let queue: Queue


    init(queue: Queue = Queue.concurrentDefaultQueue()) {
        self.queue = queue
    }


    func add(_ request: NetworkEngineRequest) -> Disposable {
        let settlement: Settlement = Settlement()
        self.queue.async({
            settlement.lock.lock()
            defer {
                settlement.lock.unlock()
            }
            if settlement.cancelled {
                return
            }

            let failure: NetworkEngineRequestFailure = NetworkEngineRequestFailure(
                error: ImpulseUnconfiguredNetworkEngine.notConfiguredError,
                info: NetworkEngineResponseInfo(timestamp: Date().timeIntervalSince1970, networkType: 0, duration: 0.0)
            )
            request.completed(.failure(failure))
        })

        return ActionDisposable(action: {
            settlement.lock.lock()
            settlement.cancelled = true
            settlement.lock.unlock()
        })
    }
}
