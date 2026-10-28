import Foundation
import SwiftSignalKit
import TelegramCore


/// The request scheduler of an `ImpulseNetworkEngineSession`. It holds the session weakly, so once the session is
/// released the requests it is given are refused and never complete.
final class ImpulseNetworkEngineRequestService: NetworkEngineRequestService {
    weak var session: ImpulseNetworkEngineSession?


    init() {
    }


    func add(_ request: NetworkEngineRequest) -> Disposable {
        guard let session: ImpulseNetworkEngineSession = self.session else {
            return EmptyDisposable
        }
        return session.add(request)
    }
}
