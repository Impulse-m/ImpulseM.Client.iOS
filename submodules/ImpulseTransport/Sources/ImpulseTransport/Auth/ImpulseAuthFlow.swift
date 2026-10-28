import Foundation


/// The outcome of a login call that answered with an authorization or with a sign-up request.
public enum ImpulseLoginResult: Equatable, Sendable {
    /// The session is in place, the identity is gone and the user lane is subscribed.
    case signedIn(userId: Int64)
    /// The account must be created first: the caller continues with `auth.signUp`.
    case signUpRequired
}


/// Why a login or a sign-out step failed.
public enum ImpulseAuthError: Error, Equatable, Sendable {
    /// The request did not produce a reply.
    case request(ImpulseRequestFailure)
    /// The authorization reply could not be decoded.
    case transcode(ImpulseTranscodeError)
    /// The authorization reply carries no session token, no refresh token or no user id.
    case incompleteAuthorization
    /// The request is not one that ends a login.
    case unexpectedMethod(String)
}


/// Sends the calls of the sign-in flow and sets the login state of the service that answers them.
public protocol ImpulseAuthRequester: Sendable {
    func execute(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions
    ) async -> Result<[UInt8], ImpulseRequestFailure>

    func setSignedIn(_ signedIn: Bool)
}


extension ImpulseRequestService: ImpulseAuthRequester {
}


/// The sign-in and sign-out flow of one account slot. The identity is minted on the pool and carried on the update
/// socket while the login calls run. A login captures the session tokens from the authorization, discards the identity,
/// rekeys the socket to the access token and subscribes the user lane. A sign-out discards the session and the identity,
/// and rekeys the socket to a fresh identity; the pool is kept.
public actor ImpulseAuthFlow {
    private static let signInMethod: String = "auth.signIn"
    private static let signUpMethod: String = "auth.signUp"
    private static let authorizationType: String = "auth.Authorization"
    private static let userType: String = "User"
    private static let authorizationArm: Int = 1
    private static let signUpRequiredArm: Int = 2
    private static let userEmptyArm: Int = 1
    private static let userArm: Int = 2
    private static let sessionTokenCapture: String = "session_token"
    private static let refreshTokenCapture: String = "refresh_token"

    /// The `flags` bits of `auth.authorization` that carry data: `otherwise_relogin_days` (bit 1), `tmp_sessions` (bit 0)
    /// and `future_auth_token` (bit 2). Each is read in TL order before the user object.
    private static let reloginDaysBit: Int32 = 1 << 1
    private static let tmpSessionsBit: Int32 = 1 << 0
    private static let futureAuthTokenBit: Int32 = 1 << 2

    private let identity: ImpulseIdentityManager
    private let tokens: ImpulseTokens
    private let storage: any ImpulseSessionStorage
    private let realtime: ImpulseRealtime
    private let requester: any ImpulseAuthRequester
    private let transcoder: ImpulseTranscoder
    private let mapping: ImpulseMapping


    public init(
        identity: ImpulseIdentityManager,
        tokens: ImpulseTokens,
        storage: any ImpulseSessionStorage,
        realtime: ImpulseRealtime,
        requester: any ImpulseAuthRequester,
        transcoder: ImpulseTranscoder,
        mapping: ImpulseMapping
    ) {
        self.identity = identity
        self.tokens = tokens
        self.storage = storage
        self.realtime = realtime
        self.requester = requester
        self.transcoder = transcoder
        self.mapping = mapping
    }


    /// Mints the identity when none is usable and carries it on the update socket, so the login calls can run.
    public func beginLogin() async throws {
        let token: String = try await identity.obtain()
        realtime.rekey(token: token)
    }


    /// Sends a login call that does not end the login, such as `auth.sendCode`, on the identity socket.
    public func sendLoginCall(_ request: ImpulseEncodedRequest) async -> Result<[UInt8], ImpulseRequestFailure> {
        return await requester.execute(request: request, options: ImpulseAuthFlow.loginOptions())
    }


    /// Sends `auth.signIn` or `auth.signUp` on the identity socket. An authorization ends the login: the tokens are
    /// stored, the identity is discarded, the socket is rekeyed to the access token and the user lane is subscribed.
    public func completeLogin(_ request: ImpulseEncodedRequest) async throws -> ImpulseLoginResult {
        guard request.method == ImpulseAuthFlow.signInMethod || request.method == ImpulseAuthFlow.signUpMethod else {
            throw ImpulseAuthError.unexpectedMethod(request.method)
        }

        let reply: [UInt8] = try await loginReply(for: request)
        let decoded: (tl: [UInt8], captured: [String: String]) = try decodeAuthorization(reply: reply)
        let tl: [UInt8] = decoded.tl
        let captured: [String: String] = decoded.captured

        let authorizationId: UInt32 = try constructorId(ofType: ImpulseAuthFlow.authorizationType, arm: ImpulseAuthFlow.authorizationArm)
        let signUpRequiredId: UInt32 = try constructorId(ofType: ImpulseAuthFlow.authorizationType, arm: ImpulseAuthFlow.signUpRequiredArm)
        let replyId: UInt32 = try readConstructorId(tl: tl)
        if replyId == signUpRequiredId {
            return .signUpRequired
        }
        guard replyId == authorizationId else {
            throw ImpulseAuthError.incompleteAuthorization
        }

        let userId: Int64 = try readUserId(tl: tl)
        guard let accessToken: String = captured[ImpulseAuthFlow.sessionTokenCapture], !accessToken.isEmpty else {
            throw ImpulseAuthError.incompleteAuthorization
        }
        guard let refreshToken: String = captured[ImpulseAuthFlow.refreshTokenCapture], !refreshToken.isEmpty else {
            throw ImpulseAuthError.incompleteAuthorization
        }
        guard userId != 0 else {
            throw ImpulseAuthError.incompleteAuthorization
        }

        let session: ImpulseSessionTokens = ImpulseSessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userId
        )
        await identity.discard()
        await tokens.onLoginTokens(session)
        requester.setSignedIn(true)
        realtime.dropIdentityLane()
        realtime.rekey(token: session.accessToken)
        realtime.apply(plan: ImpulseAuthFlow.userLanePlan(userId: userId))
        return .signedIn(userId: userId)
    }


    /// Ends the session: the session tokens and the identity are discarded, the user lane is dropped and the socket is
    /// rekeyed to a fresh identity. The pool is kept. A failed mint disconnects the socket and throws.
    public func signOut() async throws {
        let userId: Int64 = storage.load()?.userId ?? 0
        await tokens.clear()
        requester.setSignedIn(false)
        await identity.discard()
        realtime.apply(plan: ImpulseAuthFlow.dropUserLanePlan(userId: userId))
        realtime.dropSessionLane()

        let token: String
        do {
            token = try await identity.obtain()
        } catch {
            realtime.apply(plan: ImpulseAuthFlow.disconnectPlan())
            throw error
        }
        realtime.rekey(token: token)
    }


    private static func loginOptions() -> ImpulseRequestOptions {
        return ImpulseRequestOptions(withoutLogin: true)
    }


    private static func userLanePlan(userId: Int64) -> ImpulseSyncPlan {
        return ImpulseSyncPlan(
            dropUserLane: 0,
            stopLanes: false,
            disconnect: false,
            subscribeUserLane: userId,
            connect: false
        )
    }


    private static func dropUserLanePlan(userId: Int64) -> ImpulseSyncPlan {
        return ImpulseSyncPlan(
            dropUserLane: userId,
            stopLanes: true,
            disconnect: false,
            subscribeUserLane: 0,
            connect: false
        )
    }


    private static func disconnectPlan() -> ImpulseSyncPlan {
        return ImpulseSyncPlan(
            dropUserLane: 0,
            stopLanes: false,
            disconnect: true,
            subscribeUserLane: 0,
            connect: false
        )
    }


    /// Sends the login call. A failure keeps the login state closed and is reported as a request failure.
    private func loginReply(for request: ImpulseEncodedRequest) async throws -> [UInt8] {
        let settled: Result<[UInt8], ImpulseRequestFailure> = await requester.execute(
            request: request,
            options: ImpulseAuthFlow.loginOptions()
        )
        switch settled {
        case .success(let reply):
            return reply

        case .failure(let failure):
            throw ImpulseAuthError.request(failure)
        }
    }


    /// Decodes the authorization reply to TL and collects the captured tokens by field name.
    private func decodeAuthorization(reply: [UInt8]) throws -> (tl: [UInt8], captured: [String: String]) {
        var captured: [String: String] = [:]
        do {
            let tl: [UInt8] = try transcoder.protoToTlObject(
                typeName: ImpulseAuthFlow.authorizationType,
                proto: reply,
                capture: { (protoMessage: String, fieldName: String, value: String) -> Void in
                    captured[fieldName] = value
                }
            )
            return (tl: tl, captured: captured)
        } catch let error as ImpulseTranscodeError {
            throw ImpulseAuthError.transcode(error)
        }
    }


    private func constructorId(
        ofType typeName: String,
        arm: Int
    ) throws -> UInt32 {
        guard let constructor: ImpulseMappingConstructor = mapping.constructor(ofType: typeName, arm: arm) else {
            throw ImpulseAuthError.incompleteAuthorization
        }
        return constructor.id
    }


    private func readConstructorId(tl: [UInt8]) throws -> UInt32 {
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            return UInt32(bitPattern: try reader.readInt32())
        } catch {
            throw ImpulseAuthError.incompleteAuthorization
        }
    }


    /// Reads the user id of a TL `auth.authorization`: the flags, the optional fields before the user, then the user object.
    /// A `userEmpty` carries the id at once; a `user` carries two flag words before it.
    private func readUserId(tl: [UInt8]) throws -> Int64 {
        let emptyUserId: UInt32 = try constructorId(ofType: ImpulseAuthFlow.userType, arm: ImpulseAuthFlow.userEmptyArm)
        let fullUserId: UInt32 = try constructorId(ofType: ImpulseAuthFlow.userType, arm: ImpulseAuthFlow.userArm)
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            _ = try reader.readInt32()
            let flags: Int32 = try reader.readInt32()
            if (flags & ImpulseAuthFlow.reloginDaysBit) != 0 {
                _ = try reader.readInt32()
            }
            if (flags & ImpulseAuthFlow.tmpSessionsBit) != 0 {
                _ = try reader.readInt32()
            }
            if (flags & ImpulseAuthFlow.futureAuthTokenBit) != 0 {
                _ = try reader.readBytes()
            }

            let userConstructor: UInt32 = UInt32(bitPattern: try reader.readInt32())
            if userConstructor == emptyUserId {
                return try reader.readInt64()
            }
            if userConstructor == fullUserId {
                _ = try reader.readInt32()
                _ = try reader.readInt32()
                return try reader.readInt64()
            }
            throw ImpulseAuthError.incompleteAuthorization
        } catch {
            throw ImpulseAuthError.incompleteAuthorization
        }
    }
}
