import Foundation


/// The credential the update socket presents, held for synchronous reads: the access token while a session is stored,
/// else the connection identity, else nil. An empty token counts as absent.
///
/// The cache is fed, because `ImpulseTokens` has no event stream and an identity minted by `obtain()` sends no event.
/// The setters take a value directly, for a sign-in, a refresh or a clear. `synchronize(tokens:identity:)` re-reads both
/// sources, and `follow(tokens:identity:)` re-reads on every identity event. The owner calls `synchronize` after an
/// identity mint, since the mint sends no event.
public final class ImpulseConnectionCredentialCache: ImpulseConnectionCredentials, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var sessionAccessToken: String?
    private var identityToken: String?
    private var sessionStamp: UInt64 = 0
    private var identityStamp: UInt64 = 0
    private var stampCounter: UInt64 = 0


    public init() {
    }


    /// The access token while a session is stored, else the connection identity, else nil. Never sends anything.
    public func currentCredential() -> String? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        if let accessToken: String = self.sessionAccessToken {
            return accessToken
        }

        return self.identityToken
    }


    /// Sets the access token of the stored session, or nil when no session is stored. Used on sign-in, refresh and clear.
    public func setSessionAccessToken(_ accessToken: String?) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.stampCounter += 1
        self.sessionStamp = self.stampCounter
        self.sessionAccessToken = ImpulseConnectionCredentialCache.normalized(accessToken)
    }


    /// Sets the connection identity token, or nil when there is no identity. Used on a mint, a renewal, a refusal and a discard.
    public func setIdentityToken(_ token: String?) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.stampCounter += 1
        self.identityStamp = self.stampCounter
        self.identityToken = ImpulseConnectionCredentialCache.normalized(token)
    }


    /// Re-reads the stored access token and the current identity, and stores them. A read that starts after a setter
    /// call never overwrites that setter's value.
    public func synchronize(
        tokens: ImpulseTokens,
        identity: ImpulseIdentityManager
    ) async {
        let stamp: UInt64 = self.takeStamp()
        let accessToken: String? = await tokens.bearer()
        let identityValue: String? = await identity.current()
        self.apply(
            stamp: stamp,
            accessToken: accessToken,
            identityValue: identityValue
        )
    }


    /// Synchronizes now and after every identity event. The identity listener is replaced by this call.
    public func follow(
        tokens: ImpulseTokens,
        identity: ImpulseIdentityManager
    ) async {
        await identity.setListener { (event: ImpulseIdentityEvent) -> Void in
            Task {
                await self.synchronize(
                    tokens: tokens,
                    identity: identity
                )
            }
        }
        await self.synchronize(
            tokens: tokens,
            identity: identity
        )
    }


    private func takeStamp() -> UInt64 {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.stampCounter += 1
        return self.stampCounter
    }


    private func apply(
        stamp: UInt64,
        accessToken: String?,
        identityValue: String?
    ) {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        if stamp > self.sessionStamp {
            self.sessionStamp = stamp
            self.sessionAccessToken = ImpulseConnectionCredentialCache.normalized(accessToken)
        }

        if stamp > self.identityStamp {
            self.identityStamp = stamp
            self.identityToken = ImpulseConnectionCredentialCache.normalized(identityValue)
        }
    }


    private static func normalized(_ value: String?) -> String? {
        guard let text: String = value, !text.isEmpty else {
            return nil
        }

        return text
    }
}
