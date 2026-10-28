import Foundation


/// The call the telemetry sink makes to send one encoded request. The request service of the connection is the
/// app's implementation, so a batch follows the same carrier and retry rules as every other call.
public protocol ImpulseTelemetryRequester: Sendable {
    func execute(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions
    ) async -> Result<[UInt8], ImpulseRequestFailure>
}


extension ImpulseRequestService: ImpulseTelemetryRequester {
}
