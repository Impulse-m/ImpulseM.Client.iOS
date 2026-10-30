import Foundation
import SwiftSignalKit
import TelegramCore


/// The request scheduler of an unconfigured session. It completes every request at once with
/// `ImpulseUnconfiguredNetworkEngine.notConfiguredError`, without any network. A request cancelled before that is never completed.
final class ImpulseUnconfiguredRequestService: NetworkEngineRequestService {
    func add(_ request: NetworkEngineRequest) -> Disposable {
        let cancelled: Atomic<Bool> = Atomic<Bool>(value: false)
        Queue.concurrentDefaultQueue().async({
            if cancelled.with({ $0 }) {
                return
            }

            let failure: NetworkEngineRequestFailure = NetworkEngineRequestFailure(
                error: ImpulseUnconfiguredNetworkEngine.notConfiguredError,
                info: NetworkEngineResponseInfo(timestamp: Date().timeIntervalSince1970, networkType: 0, duration: 0.0)
            )
            request.completed(.failure(failure))
        })

        return ActionDisposable(action: {
            let _ = cancelled.swap(true)
        })
    }
}
