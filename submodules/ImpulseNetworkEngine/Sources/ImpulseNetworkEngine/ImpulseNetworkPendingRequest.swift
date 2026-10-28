import Foundation
import SwiftSignalKit
import TelegramCore
import ImpulseTransport


/// The error counters of one request, cumulative across its resubmissions. The counters of an earlier submission stay in
/// the context a later error is offered with, as `NetworkEngineErrorContext` documents.
struct ImpulseNetworkErrorState {
    private(set) var floodWaitSeconds: Int = 0
    private(set) var floodWaitErrorText: String?
    private(set) var serverErrorsOfEarlierSubmissions: Int = 0
    private(set) var serverErrorsOfCurrentSubmission: Int = 0
    private(set) var parseFailures: Int = 0


    var context: NetworkEngineErrorContext {
        return NetworkEngineErrorContext(
            floodWaitSeconds: self.floodWaitSeconds,
            floodWaitErrorText: self.floodWaitErrorText,
            internalServerErrorCount: self.serverErrorsOfEarlierSubmissions + self.serverErrorsOfCurrentSubmission + self.parseFailures
        )
    }


    mutating func applyFlood(seconds: Int, text: String) -> NetworkEngineErrorContext {
        self.floodWaitSeconds = seconds
        self.floodWaitErrorText = text
        return self.context
    }


    mutating func applyServerError() -> NetworkEngineErrorContext {
        self.serverErrorsOfCurrentSubmission += 1
        return self.context
    }


    mutating func applyParseFailure() -> NetworkEngineErrorContext {
        self.parseFailures += 1
        return self.context
    }


    mutating func didResubmit() {
        self.serverErrorsOfEarlierSubmissions += self.serverErrorsOfCurrentSubmission
        self.serverErrorsOfCurrentSubmission = 0
    }
}


/// A request a session carries until it completes, is cancelled, or moves to another service. Its state is read and
/// written only on the session's queue.
final class ImpulseNetworkPendingRequest {
    let request: NetworkEngineRequest
    var call: ImpulseRequestCall?
    var attempt: Int = 0
    var attemptStartedAt: Double = 0.0
    /// True once the transport has sent the request, or a failure does not rule out that the server ran it.
    var mayHaveRun: Bool = false
    var acknowledgedReported: Bool = false
    var cancelled: Bool = false
    var finished: Bool = false
    var moved: Disposable?
    /// Bumped whenever a scheduled resubmission must not run.
    var retryGeneration: Int = 0
    /// The monotonic time the next resubmission is due, while one is scheduled.
    var retryDueAt: Double?
    /// Requests waiting for this one to settle before they are sent.
    var dependents: [ImpulseNetworkPendingRequest] = []
    var errorState: ImpulseNetworkErrorState = ImpulseNetworkErrorState()


    init(request: NetworkEngineRequest) {
        self.request = request
    }
}
