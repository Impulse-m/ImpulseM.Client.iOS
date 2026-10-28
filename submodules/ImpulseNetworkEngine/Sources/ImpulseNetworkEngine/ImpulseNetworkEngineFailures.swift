import Foundation
import MtProtoKit
import ImpulseTransport


/// Classifies the failed replies a session answers for a request. Flood waits and server errors are offered to the
/// request's `shouldContinueAfterError`; the answer the server lost is never reported to the caller, and a reply
/// that does not parse is handled by the session itself.
enum ImpulseNetworkEngineFailures {
    private static let floodWaitCode: Int = 420
    private static let serverErrorCode: Int = 500
    private static let negativeServerErrorCode: Int = -500
    private static let notAcceptableCode: Int = 406
    private static let slowmodeText: String = "SLOWMODE_WAIT_"
    private static let storyFloodText: String = "STORY_SEND_FLOOD"
    private static let answerLostText: String = "PROTOCOL_ERROR_ANSWER_LOST"
    private static let parsingFailureText: String = "TL_PARSING_ERROR"

    /// The error of a call whose transport failed without a server answer. A session without a total deadline never
    /// produces it; it is kept for a call that carries one.
    static let networkFailure: MTRpcError = MTRpcError(errorCode: 500, errorDescription: "NETWORK_FAILED")


    /// A flood wait the request may wait out. Slow mode and story limits are delivered at once, as the transport does.
    static func isFlood(_ error: ImpulseRpcError) -> Bool {
        if error.code != ImpulseNetworkEngineFailures.floodWaitCode {
            return false
        }
        return !error.text.contains(ImpulseNetworkEngineFailures.slowmodeText) && !error.text.contains(ImpulseNetworkEngineFailures.storyFloodText)
    }


    /// A `500` or `-500` server error, which the request may resubmit.
    static func isServerError(_ error: ImpulseRpcError) -> Bool {
        return error.code == ImpulseNetworkEngineFailures.serverErrorCode || error.code == ImpulseNetworkEngineFailures.negativeServerErrorCode
    }


    /// `500 PROTOCOL_ERROR_ANSWER_LOST`: the server ran the call and then lost its answer.
    static func isAnswerLost(_ error: ImpulseRpcError) -> Bool {
        return error.code == ImpulseNetworkEngineFailures.serverErrorCode && error.text == ImpulseNetworkEngineFailures.answerLostText
    }


    static func isNotAcceptable(_ error: ImpulseRpcError) -> Bool {
        return error.code == ImpulseNetworkEngineFailures.notAcceptableCode
    }


    /// The error the transport gives a reply that the parser refused.
    static func isParsingFailure(_ error: ImpulseRpcError) -> Bool {
        return error == ImpulseNetworkSession.tlParsingError
    }


    /// The error a request fails with when the parser refused its reply for good.
    static func parsingFailure() -> MTRpcError {
        return MTRpcError(errorCode: 500, errorDescription: ImpulseNetworkEngineFailures.parsingFailureText)
    }


    static func rpcError(_ error: ImpulseRpcError) -> MTRpcError {
        return MTRpcError(errorCode: Int32(clamping: error.code), errorDescription: error.text)
    }
}
