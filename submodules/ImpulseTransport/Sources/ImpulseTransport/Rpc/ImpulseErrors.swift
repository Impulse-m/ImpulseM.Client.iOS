/// The class of an RPC error that tells the transport to act on the session.
public enum ImpulseAuthErrorClass: Equatable, Sendable {
    case noAuthAction
    case refreshAndRetry
    case forceLogout
}


/// The Telegram error of a call, as the transport answers it to the caller.
public struct ImpulseRpcError: Equatable, Sendable {
    /// The Telegram error code, such as 400, 401, 420 or 500.
    public let code: Int
    /// The Telegram error text, such as `FLOOD_WAIT_5`. Server texts are kept as the server sent them.
    public let text: String
    /// True for the server errors that may succeed on a later attempt (`UNAVAILABLE`, `DEADLINE_EXCEEDED`).
    public let temporary: Bool


    public init(code: Int, text: String, temporary: Bool) {
        self.code = code
        self.text = text
        self.temporary = temporary
    }
}


/// Why a call on a Centrifugo carrier did not succeed, as the SDK reported it.
public struct ImpulseCarrierFailure: Error, Equatable, Sendable {
    /// The SDK reply code. 0 when the failure is not a server reply error (a lost connection, a timeout).
    public let sdkCode: Int
    /// The application code of the reply. 0 when unset.
    public let appCode: Int
    /// The application error type of the reply. Empty when unset.
    public let appType: String
    /// The metadata of the reply. Empty when unset.
    public let metadata: [String: String]


    public init(sdkCode: Int, appCode: Int, appType: String, metadata: [String: String]) {
        self.sdkCode = sdkCode
        self.appCode = appCode
        self.appType = appType
        self.metadata = metadata
    }
}


/// The fleet a call went to. The same refused token answers with a different error on each fleet.
public enum ImpulseCarrierFleet: Equatable, Sendable {
    case update
    case media
}


/// Maps RPC error texts to the transport's auth actions, and carrier failures to the Telegram errors of a call.
public enum ImpulseErrors {
    private static let migrateDcMetadataKey: String = "migrate-dc"
    private static let floodWaitPrefixes: [String] = [
        "FLOOD_WAIT_",
        "FLOOD_PREMIUM_WAIT_",
        "SLOWMODE_WAIT_",
    ]
    private static let temporaryTexts: [String] = [
        "UNAVAILABLE",
        "DEADLINE_EXCEEDED",
    ]
    private static let backendServerTexts: [String] = [
        "UNAVAILABLE",
        "DEADLINE_EXCEEDED",
        "UNKNOWN",
        "INTERNAL",
    ]
    private static let tokenInvalidCode: Int = 103
    private static let tokenExpiredCode: Int = 109
    private static let methodInvalidCode: Int = 104
    private static let overloadedCode: Int = 111
    private static let tooLargeCode: Int = 106
    private static let cancelledCode: Int = 17


    /// The auth action for an RPC error. A missing error needs no action.
    public static func classify(_ error: ImpulseRpcError?) -> ImpulseAuthErrorClass {
        guard let error: ImpulseRpcError = error else {
            return .noAuthAction
        }
        switch error.text {
        case "AUTH_KEY_UNREGISTERED":
            return .refreshAndRetry
        case "SESSION_REVOKED", "USER_DEACTIVATED", "SESSION_EXPIRED", "AUTH_TOKEN_EXPIRED", "AUTH_KEY_INVALID":
            return .forceLogout
        default:
            return .noAuthAction
        }
    }


    /// The delay in seconds from `FLOOD_WAIT_X`, `FLOOD_PREMIUM_WAIT_X` or `SLOWMODE_WAIT_X`. Nil for any other error.
    public static func floodWaitSeconds(_ error: ImpulseRpcError?) -> Int? {
        guard let error: ImpulseRpcError = error else {
            return nil
        }
        for prefix: String in floodWaitPrefixes {
            if error.text.hasPrefix(prefix) {
                let seconds: Substring = error.text.dropFirst(prefix.count)
                return Int(seconds)
            }
        }
        return nil
    }


    /// True when the call was cancelled locally (SDK code 17).
    public static func isCancelled(_ failure: ImpulseCarrierFailure) -> Bool {
        return failure.sdkCode == cancelledCode
    }


    /// True when the server refused the token the connection or the call presented (SDK codes 103 and 109).
    public static func isTokenRefusal(_ failure: ImpulseCarrierFailure) -> Bool {
        return failure.sdkCode == tokenInvalidCode || failure.sdkCode == tokenExpiredCode
    }


    /// The Telegram error a carrier failure answers. Nil when the failure is a network failure, which the caller
    /// handles on the network path and never as an RPC error.
    public static func rpcError(from failure: ImpulseCarrierFailure, fleet: ImpulseCarrierFleet) -> ImpulseRpcError? {
        if failure.sdkCode == tokenInvalidCode {
            return tokenInvalidError(fleet: fleet)
        }
        if failure.sdkCode == tokenExpiredCode {
            return ImpulseRpcError(code: 400, text: "AUTH_TOKEN_EXPIRED", temporary: false)
        }
        if !failure.appType.isEmpty {
            return serverError(failure: failure)
        }
        if failure.sdkCode == methodInvalidCode {
            return ImpulseRpcError(code: 400, text: "METHOD_INVALID", temporary: false)
        }
        if failure.sdkCode == overloadedCode || failure.sdkCode == tooLargeCode {
            return ImpulseRpcError(code: 500, text: "INTERNAL_SERVER_ERROR", temporary: false)
        }
        return nil
    }


    private static func tokenInvalidError(fleet: ImpulseCarrierFleet) -> ImpulseRpcError {
        switch fleet {
        case .update:
            return ImpulseRpcError(code: 401, text: "AUTH_KEY_UNREGISTERED", temporary: false)
        case .media:
            return ImpulseRpcError(code: 400, text: "AUTH_TOKEN_INVALID", temporary: false)
        }
    }


    private static func serverError(failure: ImpulseCarrierFailure) -> ImpulseRpcError {
        let code: Int
        if failure.metadata[migrateDcMetadataKey] != nil {
            code = 303
        } else if backendServerTexts.contains(failure.appType) {
            code = 500
        } else if failure.appCode != 0 {
            code = failure.appCode
        } else {
            code = 400
        }
        let temporary: Bool = temporaryTexts.contains(failure.appType)
        return ImpulseRpcError(code: code, text: failure.appType, temporary: temporary)
    }
}
