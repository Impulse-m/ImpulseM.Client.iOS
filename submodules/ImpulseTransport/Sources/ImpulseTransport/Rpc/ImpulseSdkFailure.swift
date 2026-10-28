import Foundation
import SwiftCentrifuge


/// Maps the errors the SDK settles an rpc call with to the carrier failures of the transport.
internal enum ImpulseSdkFailure {
    /// The failure of a call that got no server answer: a lost connection, a timeout, or an error that is not an SDK reply.
    internal static var networkFailure: ImpulseCarrierFailure {
        return ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:])
    }


    /// The carrier failure of an SDK error. A server reply keeps its codes; any other error has code 0.
    internal static func carrierFailure(from error: Error) -> ImpulseCarrierFailure {
        guard let sdkError: CentrifugeError = error as? CentrifugeError else {
            return ImpulseSdkFailure.networkFailure
        }
        switch sdkError {
        case .replyErrorDetails(let details):
            return ImpulseCarrierFailure(
                sdkCode: Int(details.code),
                appCode: Int(details.appCode),
                appType: details.appType,
                metadata: details.metadata
            )

        case .replyError(let code, _, _):
            return ImpulseCarrierFailure(sdkCode: Int(code), appCode: 0, appType: "", metadata: [:])

        case .clientRejected(let code, _):
            return ImpulseCarrierFailure(sdkCode: Int(code), appCode: 0, appType: "", metadata: [:])

        default:
            return ImpulseSdkFailure.networkFailure
        }
    }
}
