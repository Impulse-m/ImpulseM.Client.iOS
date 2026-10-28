import Foundation


/// Why a telemetry batch was not sent.
public enum ImpulseTelemetrySinkError: Error, Equatable, Sendable {
    /// The batch could not be encoded as a request, with the reason of the transcoder.
    case encodeFailed(String)
    /// The encoded request is not `help.saveAppLog`.
    case unexpectedMethod(String)
    /// The request service ended the call without a reply.
    case requestFailed(ImpulseRequestFailure)
}


/// Sends each telemetry batch as one `help.saveAppLog` through the request service. The call needs no login, does not
/// wait out a flood wait and is not retried after a server error: a batch that fails is dropped by `ImpulseTelemetry`.
/// Network failures are retried until the total deadline.
public struct ImpulseRequestTelemetrySink: ImpulseTelemetrySink {
    /// The method every batch is sent as.
    public static let methodName: String = "help.saveAppLog"
    /// The options every batch is sent with.
    public static let requestOptions: ImpulseRequestOptions = ImpulseRequestOptions(
        withoutLogin: true,
        failOnServerErrors: true,
        doNotWaitFloodWait: true,
        totalDeadlineSeconds: ImpulseRequestTimeouts.updateCallSeconds
    )


    private let transcoder: ImpulseTranscoder
    private let requester: any ImpulseTelemetryRequester


    public init(
        transcoder: ImpulseTranscoder,
        requester: any ImpulseTelemetryRequester
    ) {
        self.transcoder = transcoder
        self.requester = requester
    }


    public func saveAppLog(request: [UInt8]) async throws {
        let encoded: ImpulseEncodedRequest
        do {
            encoded = try self.transcoder.encodeRequest(tl: request)
        } catch {
            let reason: String = (error as? ImpulseTranscodeError)?.reason ?? String(describing: error)
            throw ImpulseTelemetrySinkError.encodeFailed(reason)
        }

        guard encoded.method == ImpulseRequestTelemetrySink.methodName else {
            throw ImpulseTelemetrySinkError.unexpectedMethod(encoded.method)
        }

        let result: Result<[UInt8], ImpulseRequestFailure> = await self.requester.execute(
            request: encoded,
            options: ImpulseRequestTelemetrySink.requestOptions
        )
        switch result {
        case .success:
            return

        case .failure(let failure):
            throw ImpulseTelemetrySinkError.requestFailed(failure)
        }
    }
}
