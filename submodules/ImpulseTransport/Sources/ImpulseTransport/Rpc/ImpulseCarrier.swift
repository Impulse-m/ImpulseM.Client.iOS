import Foundation


/// Where a call goes: a carrier, or a local refusal that answers it without a round trip.
public enum ImpulseCarrierRoute: Equatable, Sendable {
    /// The update socket, which carries RPC calls and the realtime lanes.
    case update
    /// The media fleet, for the four media methods.
    case media
    /// The token-less pool, for the pool-only methods.
    case pool
    /// A local refusal. The call is never sent to the server.
    case refused(ImpulseRpcError)
}


/// Chooses the carrier of an RPC method and maps the failure of a carrier call to the Telegram error of the call.
public enum ImpulseCarrier {
    public static let identityRefusalError: ImpulseRpcError = ImpulseRpcError(
        code: 400,
        text: "CLIENT_IDENTITY_REFUSED",
        temporary: false
    )


    private static let poolOnlyMethods: Set<String> = [
        "connectionIdentity",
        "refreshSession",
    ]
    private static let takeoutMethod: String = "invokeWithTakeout"


    /// The carrier of a method for a socket with or without a session. Pool-only methods always go to the pool.
    /// Takeout always goes to the update socket, on either credential, and is never refused or answered here.
    /// A method that the socket's class does not allow is refused locally. Every other method goes to the update
    /// socket, except the media methods, which go to the media fleet. `upload.getCdnFile` and `upload.getFileHashes`
    /// are not media methods, so they stay on the update socket.
    public static func route(
        method: String,
        signedIn: Bool
    ) -> ImpulseCarrierRoute {
        if ImpulseCarrier.poolOnlyMethods.contains(method) {
            return .pool
        }

        if method == ImpulseCarrier.takeoutMethod {
            return .update
        }

        if !ImpulseMethodClasses.allowed(signedIn: signedIn, method: method) {
            return .refused(ImpulseCarrier.identityRefusalError)
        }

        if ImpulseMethodClasses.mediaMethods.contains(method) {
            return .media
        }

        return .update
    }


    /// The Telegram error a failed carrier call answers. A refused route has no carrier failure, so it answers its own
    /// refusal. The pool carries no token, so its failures use the update fleet's mapping. Nil for network failures.
    public static func rpcError(
        from failure: ImpulseCarrierFailure,
        route: ImpulseCarrierRoute
    ) -> ImpulseRpcError? {
        switch route {
        case .refused(let error):
            return error
        case .update, .pool:
            return ImpulseErrors.rpcError(from: failure, fleet: .update)
        case .media:
            return ImpulseErrors.rpcError(from: failure, fleet: .media)
        }
    }
}
