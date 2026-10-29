import Foundation


/// Installs the session that a login reply carries. The sign-in flow and the live reply path run the same steps in one
/// order: the tokens are stored, the identity is discarded, the socket is rekeyed to the access token, the user lane is
/// subscribed, the requests that wait for a login are released, and the connection is declared on the session credential.
public actor ImpulseSessionInstaller {
    private static let authorizationType: String = "auth.Authorization"
    private static let authorizationArm: Int = 1
    private static let userType: String = "User"
    private static let userEmptyArm: Int = 1
    private static let userArm: Int = 2
    private static let loginTokenSuccessPredicate: String = "auth.loginTokenSuccess"
    private static let sentCodeSuccessPredicate: String = "auth.sentCodeSuccess"
    private static let sessionTokenCapture: String = "session_token"
    private static let refreshTokenCapture: String = "refresh_token"
    /// The constructor id that wraps the authorization of `auth.loginTokenSuccess` and `auth.sentCodeSuccess`.
    private static let wrapperIdLength: Int = 4

    /// The `flags` bits of `auth.authorization` that carry data: `otherwise_relogin_days` (bit 1), `tmp_sessions` (bit 0)
    /// and `future_auth_token` (bit 2). Each is read in TL order before the user object.
    private static let reloginDaysBit: Int32 = 1 << 1
    private static let tmpSessionsBit: Int32 = 1 << 0
    private static let futureAuthTokenBit: Int32 = 1 << 2

    private let identity: ImpulseIdentityManager
    private let tokens: ImpulseTokens
    private let realtime: ImpulseRealtime
    private let mapping: ImpulseMapping
    private let setSignedIn: @Sendable (Bool) -> Void
    private let credentials: ImpulseConnectionCredentialCache?
    private let declarer: ImpulseConnectionDeclarer?


    public init(
        identity: ImpulseIdentityManager,
        tokens: ImpulseTokens,
        realtime: ImpulseRealtime,
        mapping: ImpulseMapping,
        setSignedIn: @escaping @Sendable (Bool) -> Void,
        credentials: ImpulseConnectionCredentialCache?,
        declarer: ImpulseConnectionDeclarer?
    ) {
        self.identity = identity
        self.tokens = tokens
        self.realtime = realtime
        self.mapping = mapping
        self.setSignedIn = setSignedIn
        self.credentials = credentials
        self.declarer = declarer
    }


    /// The authorization of a login reply, of any method: the reply itself when it is an `auth.Authorization`, or the
    /// authorization inside an `auth.loginTokenSuccess` or an `auth.sentCodeSuccess`. Nil for any other reply.
    public func authorization(inResult result: [UInt8]) -> [UInt8]? {
        guard let replyId: UInt32 = ImpulseSessionInstaller.constructorId(of: result) else {
            return nil
        }

        if let authorizationId: UInt32 = self.mapping.constructor(
            ofType: ImpulseSessionInstaller.authorizationType,
            arm: ImpulseSessionInstaller.authorizationArm
        )?.id, replyId == authorizationId {
            return result
        }

        let wrapperPredicates: [String] = [
            ImpulseSessionInstaller.loginTokenSuccessPredicate,
            ImpulseSessionInstaller.sentCodeSuccessPredicate,
        ]
        for predicate: String in wrapperPredicates {
            if let wrapperId: UInt32 = self.constructorId(predicate: predicate), wrapperId == replyId {
                return Array(result.dropFirst(ImpulseSessionInstaller.wrapperIdLength))
            }
        }
        return nil
    }


    /// Installs the session of an authorization. The tokens are taken from `captured`, the user id from `authorization`.
    /// Returns the user id. Throws when a token or the user id is missing, and then nothing is changed.
    public func install(
        method: String,
        authorization: [UInt8],
        captured: [String: String]
    ) async throws -> Int64 {
        let userId: Int64 = try self.readUserId(tl: authorization)
        guard let accessToken: String = captured[ImpulseSessionInstaller.sessionTokenCapture], !accessToken.isEmpty else {
            throw ImpulseAuthError.incompleteAuthorization
        }
        guard let refreshToken: String = captured[ImpulseSessionInstaller.refreshTokenCapture], !refreshToken.isEmpty else {
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
        await self.identity.discard()
        await self.tokens.onLoginTokens(session)
        self.credentials?.setSessionAccessToken(session.accessToken)
        self.realtime.dropIdentityLane()
        self.realtime.rekey(token: session.accessToken)
        self.realtime.apply(plan: ImpulseSessionInstaller.userLanePlan(userId: userId))
        self.setSignedIn(true)
        await self.declarer?.sessionChanged()
        ImpulseDiagnostics.log("The session is installed by \(method) for user \(userId)")
        return userId
    }


    private static func constructorId(of tl: [UInt8]) -> UInt32? {
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            return UInt32(bitPattern: try reader.readInt32())
        } catch {
            return nil
        }
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


    private func constructorId(predicate: String) -> UInt32? {
        return self.mapping.constructors.first(where: { (candidate: ImpulseMappingConstructor) -> Bool in
            return candidate.predicate == predicate
        })?.id
    }


    private func constructorId(
        ofType typeName: String,
        arm: Int
    ) throws -> UInt32 {
        guard let constructor: ImpulseMappingConstructor = self.mapping.constructor(ofType: typeName, arm: arm) else {
            throw ImpulseAuthError.incompleteAuthorization
        }
        return constructor.id
    }


    /// Reads the user id of a TL `auth.authorization`: the flags, the optional fields before the user, then the user object.
    /// A `userEmpty` carries the id at once; a `user` carries two flag words before it.
    private func readUserId(tl: [UInt8]) throws -> Int64 {
        let emptyUserId: UInt32 = try self.constructorId(
            ofType: ImpulseSessionInstaller.userType,
            arm: ImpulseSessionInstaller.userEmptyArm
        )
        let fullUserId: UInt32 = try self.constructorId(
            ofType: ImpulseSessionInstaller.userType,
            arm: ImpulseSessionInstaller.userArm
        )
        do {
            var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
            _ = try reader.readInt32()
            let flags: Int32 = try reader.readInt32()
            if (flags & ImpulseSessionInstaller.reloginDaysBit) != 0 {
                _ = try reader.readInt32()
            }
            if (flags & ImpulseSessionInstaller.tmpSessionsBit) != 0 {
                _ = try reader.readInt32()
            }
            if (flags & ImpulseSessionInstaller.futureAuthTokenBit) != 0 {
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
