import Foundation


/// The tokens of one signed-in session. They are stored together as one blob.
public struct ImpulseSessionTokens: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let userId: Int64


    public init(
        accessToken: String,
        refreshToken: String,
        userId: Int64
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
    }
}


/// Persistent storage for the session. A save replaces both tokens at once.
public protocol ImpulseSessionStorage: Sendable {
    /// Returns nil when no session is stored.
    func load() -> ImpulseSessionTokens?

    func save(_ tokens: ImpulseSessionTokens)

    func clear()
}


/// The carrier a refresh goes over: the update socket while its access token works, the token-less pool fleet once the
/// access token has expired or the server has refused it.
public enum ImpulseRefreshCarrier: Equatable, Sendable {
    case updateSocket
    case poolFleet
}


/// The authorization the server answers a refresh with.
public struct ImpulseRefreshAuthorization: Equatable, Sendable {
    public let userId: Int64
    public let sessionToken: String
    public let refreshToken: String
    /// Seconds during which a replaced refresh token still answers the same session.
    public let grace: Int


    public init(
        userId: Int64,
        sessionToken: String,
        refreshToken: String,
        grace: Int
    ) {
        self.userId = userId
        self.sessionToken = sessionToken
        self.refreshToken = refreshToken
        self.grace = grace
    }
}


/// The answer to a refresh sent over a carrier: the server's authorization, or the carrier's failure.
public enum ImpulseRefreshReply: Equatable, Sendable {
    case authorization(ImpulseRefreshAuthorization)
    case failure(ImpulseCarrierFailure)
}


/// Sends `auth.refreshSession` over the carrier asked for. A transport fault is thrown and keeps the session.
public protocol ImpulseRefreshTransport: Sendable {
    func refreshSession(
        refreshToken: String,
        carrier: ImpulseRefreshCarrier,
        timeoutSeconds: TimeInterval
    ) async throws -> ImpulseRefreshReply
}


/// What a refresh call ended with.
public enum ImpulseRefreshOutcome: Equatable, Sendable {
    /// A fresh session is in place.
    case refreshed
    /// The server asked for a wait (FLOOD_WAIT). The current access token stays in use until `retryAt` and no request
    /// is sent before it. The owner of the connection retries at `retryAt`.
    case deferred(retryAt: Date)
    /// No session is stored, so there is nothing to refresh.
    case noSession
    /// The session was unrecoverable or ended during the refresh, and it has been cleared.
    case sessionEnded
}


/// A refresh failure that keeps the session.
public enum ImpulseTokenError: Error, Equatable, Sendable {
    /// The server refused the refresh with an error that neither ends the session nor fits the wait window.
    case refreshRejected(ImpulseRpcError)
    /// The carrier failed without a server reply, such as a lost connection or a timeout.
    case carrierFailure(ImpulseCarrierFailure)
    /// The reply carried no session tokens or no user id.
    case incompleteReply
}


/// Holds the session and refreshes it, with one refresh on the wire at a time. The access token is refreshed over the
/// update socket while it works, and over the pool fleet once it has expired or was refused.
public actor ImpulseTokens {
    /// The refresh point is drawn uniformly in [exp - 300 s, exp - 120 s].
    public static let refreshWindowStartSeconds: TimeInterval = 300
    public static let refreshWindowEndSeconds: TimeInterval = 120
    public static let refreshTimeoutSeconds: TimeInterval = 30

    private static let floodWaitCode: Int = 420
    private static let slowmodePrefix: String = "SLOWMODE_WAIT_"
    private static let unrecoverableTexts: Set<String> = [
        "AUTH_TOKEN_INVALID",
        "AUTH_TOKEN_EXPIRED",
        "SESSION_EXPIRED",
    ]

    private let storage: any ImpulseSessionStorage
    private let transport: any ImpulseRefreshTransport
    private let clock: @Sendable () -> Date
    private let randomUnit: @Sendable () -> Double
    private var held: ImpulseSessionTokens?
    private var refreshPoint: Date?
    private var refusedAccessToken: String?
    private var rotation: ImpulseRefreshRotation?
    private var deferredUntil: Date?
    private var inFlight: Task<ImpulseRefreshOutcome, Error>?
    private var clearGeneration: Int = 0


    public init(
        storage: any ImpulseSessionStorage,
        transport: any ImpulseRefreshTransport,
        clock: @escaping @Sendable () -> Date = { Date() },
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.storage = storage
        self.transport = transport
        self.clock = clock
        self.randomUnit = randomUnit

        if let loaded: ImpulseSessionTokens = storage.load() {
            self.held = loaded
            self.refreshPoint = ImpulseTokens.drawRefreshPoint(
                accessToken: loaded.accessToken,
                now: clock(),
                randomUnit: randomUnit
            )
        }
    }


    /// The stored access token, or nil without a session.
    public func bearer() -> String? {
        guard let current: ImpulseSessionTokens = held else {
            return nil
        }

        return current.accessToken
    }


    public func hasSession() -> Bool {
        return held != nil
    }


    /// The date of the stored access token's refresh point, or nil when there is no session or the token is opaque.
    public func refreshPointDate() -> Date? {
        return refreshPoint
    }


    /// True once the refresh point drawn for the stored access token has passed.
    public func needsProactiveRefresh() -> Bool {
        guard let current: ImpulseSessionTokens = held else {
            return false
        }

        if current.accessToken.isEmpty || current.refreshToken.isEmpty {
            return false
        }

        guard let point: Date = refreshPoint else {
            return false
        }

        return clock() >= point
    }


    /// True when the stored access token is refused, or its exp has passed. An opaque token is never unusable.
    public func accessUnusable() -> Bool {
        guard let current: ImpulseSessionTokens = held else {
            return false
        }

        if current.accessToken.isEmpty {
            return false
        }

        if current.accessToken == refusedAccessToken {
            return true
        }

        guard let expirySeconds: Int64 = ImpulseTokens.expiry(ofJwt: current.accessToken) else {
            return false
        }

        return clock().timeIntervalSince1970 >= TimeInterval(expirySeconds)
    }


    /// Stores a session that a login produced.
    public func onLoginTokens(_ tokens: ImpulseSessionTokens) {
        installTokens(tokens)
    }


    /// Remembers that the server refused this access token.
    public func markRefused(accessToken: String) {
        refusedAccessToken = accessToken
    }


    /// Ends the session: the stored tokens are removed and any deferred refresh is dropped.
    public func clear() {
        endSession()
    }


    /// The token the update socket connects with. An unusable access token is refreshed first. Returns nil without a
    /// session, or when the session ended during that refresh.
    public func connectionToken() async throws -> String? {
        if held == nil {
            return nil
        }

        if accessUnusable() {
            let outcome: ImpulseRefreshOutcome = try await refresh()
            switch outcome {
            case .refreshed, .deferred:
                break
            case .noSession, .sessionEnded:
                return nil
            }
        }

        return bearer()
    }


    /// Refreshes the session. Callers that arrive while a refresh is on the wire share its outcome, so a refresh token
    /// is never sent twice in parallel.
    public func refresh() async throws -> ImpulseRefreshOutcome {
        if let retryAt: Date = pendingRetry() {
            return .deferred(retryAt: retryAt)
        }

        if let running: Task<ImpulseRefreshOutcome, Error> = inFlight {
            return try await running.value
        }

        let task: Task<ImpulseRefreshOutcome, Error> = Task {
            try await self.performRefresh()
        }
        inFlight = task

        let outcome: ImpulseRefreshOutcome
        do {
            outcome = try await task.value
        } catch {
            inFlight = nil
            throw error
        }

        inFlight = nil
        return outcome
    }


    private func performRefresh() async throws -> ImpulseRefreshOutcome {
        guard let current: ImpulseSessionTokens = held else {
            return .noSession
        }

        if current.refreshToken.isEmpty {
            return .noSession
        }

        let startedClearGeneration: Int = clearGeneration
        let sentRefreshToken: String = current.refreshToken
        var carrier: ImpulseRefreshCarrier = accessUnusable() ? .poolFleet : .updateSocket
        var reply: ImpulseRefreshReply = try await transport.refreshSession(
            refreshToken: sentRefreshToken,
            carrier: carrier,
            timeoutSeconds: ImpulseTokens.refreshTimeoutSeconds
        )

        if case .failure(let socketFailure) = reply, carrier == .updateSocket, ImpulseErrors.isTokenRefusal(socketFailure) {
            carrier = .poolFleet
            reply = try await transport.refreshSession(
                refreshToken: sentRefreshToken,
                carrier: carrier,
                timeoutSeconds: ImpulseTokens.refreshTimeoutSeconds
            )
        }

        if clearGeneration != startedClearGeneration {
            return .sessionEnded
        }

        switch reply {
        case .authorization(let authorization):
            return try store(authorization, replacing: sentRefreshToken)
        case .failure(let failure):
            return try handleFailure(failure, current: current, sentRefreshToken: sentRefreshToken)
        }
    }


    private func store(
        _ authorization: ImpulseRefreshAuthorization,
        replacing sentRefreshToken: String
    ) throws -> ImpulseRefreshOutcome {
        if authorization.sessionToken.isEmpty || authorization.refreshToken.isEmpty || authorization.userId == 0 {
            throw ImpulseTokenError.incompleteReply
        }

        if authorization.refreshToken != sentRefreshToken {
            rotation = ImpulseRefreshRotation(
                replacedRefreshToken: sentRefreshToken,
                replacedAt: clock(),
                graceSeconds: authorization.grace
            )
        }

        installTokens(
            ImpulseSessionTokens(
                accessToken: authorization.sessionToken,
                refreshToken: authorization.refreshToken,
                userId: authorization.userId
            )
        )
        return .refreshed
    }


    private func handleFailure(
        _ failure: ImpulseCarrierFailure,
        current: ImpulseSessionTokens,
        sentRefreshToken: String
    ) throws -> ImpulseRefreshOutcome {
        // A refused token is answered as on the media fleet; the pool retry above already covered a refused socket token.
        guard let error: ImpulseRpcError = ImpulseErrors.rpcError(from: failure, fleet: .media) else {
            throw ImpulseTokenError.carrierFailure(failure)
        }

        if ImpulseTokens.isUnrecoverable(error) {
            // A refusal of a refresh token replaced within the grace window keeps the session, and is reported as a
            // refused refresh: no new pair was received, so the held pair is not fresh and must not be reported as such.
            if isWithinGrace(replacedRefreshToken: sentRefreshToken) {
                throw ImpulseTokenError.refreshRejected(error)
            }

            endSession()
            return .sessionEnded
        }

        if let retryAt: Date = deferralDate(after: error, accessToken: current.accessToken) {
            deferredUntil = retryAt
            return .deferred(retryAt: retryAt)
        }

        throw ImpulseTokenError.refreshRejected(error)
    }


    /// The retry date of a FLOOD_WAIT refusal, when the retry lands before exp - 120 s. Nil when it does not.
    private func deferralDate(
        after error: ImpulseRpcError,
        accessToken: String
    ) -> Date? {
        if error.code != ImpulseTokens.floodWaitCode || error.text.hasPrefix(ImpulseTokens.slowmodePrefix) {
            return nil
        }

        guard let waitSeconds: Int = ImpulseErrors.floodWaitSeconds(error) else {
            return nil
        }

        guard let expirySeconds: Int64 = ImpulseTokens.expiry(ofJwt: accessToken) else {
            return nil
        }

        let landing: Date = clock().addingTimeInterval(TimeInterval(waitSeconds))
        let windowClose: TimeInterval = TimeInterval(expirySeconds) - ImpulseTokens.refreshWindowEndSeconds
        if landing.timeIntervalSince1970 >= windowClose {
            return nil
        }

        return landing
    }


    private func pendingRetry() -> Date? {
        guard let retryAt: Date = deferredUntil else {
            return nil
        }

        if clock() < retryAt {
            return retryAt
        }

        deferredUntil = nil
        return nil
    }


    private func isWithinGrace(replacedRefreshToken: String) -> Bool {
        guard let latest: ImpulseRefreshRotation = rotation else {
            return false
        }

        if latest.replacedRefreshToken != replacedRefreshToken {
            return false
        }

        let graceEnd: Date = latest.replacedAt.addingTimeInterval(TimeInterval(latest.graceSeconds))
        return clock() < graceEnd
    }


    private func installTokens(_ tokens: ImpulseSessionTokens) {
        held = tokens
        refreshPoint = ImpulseTokens.drawRefreshPoint(
            accessToken: tokens.accessToken,
            now: clock(),
            randomUnit: randomUnit
        )
        refusedAccessToken = nil
        deferredUntil = nil
        storage.save(tokens)
    }


    private func endSession() {
        clearGeneration += 1
        storage.clear()
        held = nil
        refreshPoint = nil
        refusedAccessToken = nil
        rotation = nil
        deferredUntil = nil
    }


    /// The refresh point drawn for an access token. Nil for an opaque token. When less than 120 s remain, the point is now.
    private static func drawRefreshPoint(
        accessToken: String,
        now: Date,
        randomUnit: () -> Double
    ) -> Date? {
        guard let expirySeconds: Int64 = ImpulseTokens.expiry(ofJwt: accessToken) else {
            return nil
        }

        let expiry: TimeInterval = TimeInterval(expirySeconds)
        let nowSeconds: TimeInterval = now.timeIntervalSince1970
        let windowEnd: TimeInterval = expiry - ImpulseTokens.refreshWindowEndSeconds
        if windowEnd <= nowSeconds {
            return now
        }

        let windowStart: TimeInterval = max(nowSeconds, expiry - ImpulseTokens.refreshWindowStartSeconds)
        let point: TimeInterval = windowStart + randomUnit() * (windowEnd - windowStart)
        return Date(timeIntervalSince1970: point)
    }


    private static func isUnrecoverable(_ error: ImpulseRpcError) -> Bool {
        return unrecoverableTexts.contains(error.text)
    }


    /// The exp claim in unix seconds, or nil when the token is not a JWT whose payload carries a positive exp.
    /// The signature is not checked: the server verifies the token, the client only schedules around its times.
    private static func expiry(ofJwt token: String) -> Int64? {
        let segments: [Substring] = token.split(separator: ".", omittingEmptySubsequences: false)
        if segments.count < 3 {
            return nil
        }

        guard let payload: Data = decodeBase64Url(String(segments[1])) else {
            return nil
        }

        guard let object: Any = try? JSONSerialization.jsonObject(with: payload) else {
            return nil
        }

        guard let claims: [String: Any] = object as? [String: Any] else {
            return nil
        }

        guard let number: NSNumber = claims["exp"] as? NSNumber else {
            return nil
        }

        let value: Int64 = number.int64Value
        return value > 0 ? value : nil
    }


    private static func decodeBase64Url(_ segment: String) -> Data? {
        var base64: String = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder: Int = base64.count % 4
        if remainder == 1 {
            return nil
        }

        if remainder == 2 {
            base64 += "=="
        } else if remainder == 3 {
            base64 += "="
        }

        return Data(base64Encoded: base64)
    }
}


/// The refresh token a successful refresh replaced, with the time of the replacement and the grace the server gave.
private struct ImpulseRefreshRotation {
    let replacedRefreshToken: String
    let replacedAt: Date
    let graceSeconds: Int
}
