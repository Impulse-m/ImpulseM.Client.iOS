import Foundation


/// Sends `connectionIdentity` on a carrier. An empty identity token mints; a non-empty one renews that identity.
public protocol ImpulseIdentityCarrier: Sendable {
    /// Returns the identity token of the reply. An empty string is a null identity.
    func connectionIdentity(
        identityToken: String,
        apiId: Int32,
        timeoutSeconds: Double
    ) async throws -> String
}


/// Reads and writes the key-value store that keeps the identity token across restarts.
public protocol ImpulseIdentityStore: Sendable {
    func string(forKey key: String) -> String?

    func setString(
        _ value: String,
        forKey key: String
    )

    func removeValue(forKey key: String)
}


/// The wall clock in unix seconds. A test clock replaces it.
public protocol ImpulseIdentityClock: Sendable {
    func nowUnixSeconds() -> Double
}


/// Waits for a number of seconds. Throws when the waiting task is cancelled.
public protocol ImpulseIdentityScheduler: Sendable {
    func sleep(seconds: Double) async throws
}


/// Tells the transport what happened to the identity: the socket reconnects on `changed`, and hands the token on `renewed`.
public enum ImpulseIdentityEvent: Equatable, Sendable {
    /// The same identity received a renewed token.
    case renewed(token: String)

    /// A different identity replaced the current one, or the current one was refused.
    case changed
}


/// Why the connection identity could not be obtained from a reply that the carrier delivered.
public enum ImpulseIdentityError: Error, Equatable, Sendable {
    case emptyReply
    case unreadableToken
    case expiredToken
    case discardedWhileMinting
}


/// The wall clock of the system.
public struct ImpulseSystemClock: ImpulseIdentityClock {
    public init() {
    }


    public func nowUnixSeconds() -> Double {
        return Date().timeIntervalSince1970
    }
}


/// Sleeps on the Swift concurrency clock.
public struct ImpulseTaskScheduler: ImpulseIdentityScheduler {
    public init() {
    }


    public func sleep(seconds: Double) async throws {
        let nanoseconds: UInt64 = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}


/// The connection identity of one account slot while it is signed out. The manager is an actor: calls are serialised.
public actor ImpulseIdentityManager {
    private let poolCarrier: any ImpulseIdentityCarrier
    private let store: any ImpulseIdentityStore
    private let clock: any ImpulseIdentityClock
    private let scheduler: any ImpulseIdentityScheduler
    private let apiId: Int32
    private let drawFraction: @Sendable () -> Double

    private var identity: ImpulseIdentityRecord?
    private var epoch: Int = 0
    private var mintFlight: Task<String, any Error>?
    private var renewalTask: Task<Void, Never>?
    private var renewalCarrier: (any ImpulseIdentityCarrier)?
    private var listener: (@Sendable (ImpulseIdentityEvent) -> Void)?


    /// Loads the stored identity: a token still usable becomes current, anything else is cleared from the store.
    public init(
        poolCarrier: any ImpulseIdentityCarrier,
        store: any ImpulseIdentityStore,
        clock: any ImpulseIdentityClock,
        scheduler: any ImpulseIdentityScheduler,
        apiId: Int32,
        drawFraction: @escaping @Sendable () -> Double = ImpulseIdentityManager.randomFraction
    ) {
        self.poolCarrier = poolCarrier
        self.store = store
        self.clock = clock
        self.scheduler = scheduler
        self.apiId = apiId
        self.drawFraction = drawFraction
        self.identity = ImpulseIdentityManager.loadStored(store: store, clock: clock)
    }


    /// A uniform draw in [0, 1) for the renewal point.
    public static func randomFraction() -> Double {
        return Double.random(in: 0..<1)
    }


    /// Schedules the renewal of the identity loaded at init. Call once after the renewal carrier is set.
    public func start() {
        guard let record: ImpulseIdentityRecord = identity else {
            return
        }

        startRenewal(of: record, epochAtInstall: epoch)
    }


    /// The update socket that renews the identity. Renewal is skipped while it is nil.
    public func setRenewalCarrier(_ carrier: (any ImpulseIdentityCarrier)?) {
        renewalCarrier = carrier
    }


    public func setListener(_ newListener: (@Sendable (ImpulseIdentityEvent) -> Void)?) {
        listener = newListener
    }


    /// The current token if it is usable, else nil. Never sends anything. An unusable identity is dropped here.
    public func current() -> String? {
        guard let record: ImpulseIdentityRecord = identity else {
            return nil
        }

        if ImpulseIdentityRules.isUsable(record.claims, nowSeconds: clock.nowUnixSeconds()) {
            return record.token
        }

        identity = nil
        store.removeValue(forKey: ImpulseIdentityRules.storageKey)
        return nil
    }


    /// The current token, or a new one minted on the pool carrier. Concurrent callers share one mint.
    public func obtain() async throws -> String {
        if let token: String = current() {
            return token
        }

        if let flight: Task<String, any Error> = mintFlight {
            return try await flight.value
        }

        let flight: Task<String, any Error> = Task {
            try await self.performMint()
        }
        mintFlight = flight
        return try await flight.value
    }


    /// Forgets the identity: memory and store, and cancels the renewal. A mint in flight then fails.
    public func discard() {
        discardIdentity()
    }


    /// The server refused this token. If it is the current one, it is discarded and the listener is told to reconnect.
    @discardableResult
    public func refuse(_ refusedToken: String) -> Bool {
        guard let record: ImpulseIdentityRecord = identity, record.token == refusedToken else {
            return false
        }

        discardIdentity()
        notify(.changed)
        return true
    }


    func currentRecord() -> ImpulseIdentityRecord? {
        return identity
    }


    var currentEpoch: Int {
        return epoch
    }


    /// One renewal of `renewing`: waits for its renewal point, then retries failures with a doubling delay while the
    /// retry lands before exp - 120 s. Returns the installed renewal, or nil when the renewal ends without one.
    func runRenewal(
        of renewing: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) async -> ImpulseIdentityInstall? {
        let startSeconds: Double = clock.nowUnixSeconds()
        let point: Double = ImpulseIdentityRules.renewalPoint(
            expSeconds: renewing.claims.exp,
            nowSeconds: startSeconds,
            fraction: drawFraction()
        )
        let slept: Bool = await sleepSeconds(max(0, point - startSeconds))
        guard slept else {
            return nil
        }

        var retrySeconds: Double = ImpulseIdentityRules.firstRetrySeconds
        while true {
            guard isCurrent(renewing, epochAtInstall: epochAtInstall), let carrier: any ImpulseIdentityCarrier = renewalCarrier else {
                return nil
            }

            do {
                let next: ImpulseIdentityRecord = try await requestIdentity(
                    carrier: carrier,
                    identityToken: renewing.token,
                    timeoutSeconds: ImpulseIdentityRules.renewTimeoutSeconds
                )
                return applyRenewal(
                    from: renewing,
                    to: next,
                    epochAtInstall: epochAtInstall
                )
            } catch {
                let landingSeconds: Double = clock.nowUnixSeconds() + retrySeconds
                guard landingSeconds < renewing.claims.exp - ImpulseIdentityRules.refreshWindowEndSeconds else {
                    return nil
                }

                let retried: Bool = await sleepSeconds(retrySeconds)
                guard retried else {
                    return nil
                }

                retrySeconds = min(retrySeconds * 2, ImpulseIdentityRules.maxRetrySeconds)
            }
        }
    }


    /// Renews the identity until a renewal ends without one, then drops it at exp - 60 s unless it was replaced.
    func renewalLoop(
        from record: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) async {
        var renewing: ImpulseIdentityRecord = record
        var epochAtStart: Int = epochAtInstall
        while let install: ImpulseIdentityInstall = await runRenewal(of: renewing, epochAtInstall: epochAtStart) {
            renewing = install.record
            epochAtStart = install.epoch
        }

        let remainingSeconds: Double = renewing.claims.exp - ImpulseIdentityRules.expiryMarginSeconds - clock.nowUnixSeconds()
        let slept: Bool = await sleepSeconds(max(0, remainingSeconds))
        guard slept else {
            return
        }

        expireIdentity(renewing, epochAtInstall: epochAtStart)
    }


    private static func loadStored(
        store: any ImpulseIdentityStore,
        clock: any ImpulseIdentityClock
    ) -> ImpulseIdentityRecord? {
        guard let stored: String = store.string(forKey: ImpulseIdentityRules.storageKey) else {
            return nil
        }

        if let record: ImpulseIdentityRecord = ImpulseIdentityRecord.read(token: stored),
           ImpulseIdentityRules.isUsable(record.claims, nowSeconds: clock.nowUnixSeconds()) {
            return record
        }

        store.removeValue(forKey: ImpulseIdentityRules.storageKey)
        return nil
    }


    private func performMint() async throws -> String {
        let startEpoch: Int = epoch
        defer {
            if epoch == startEpoch {
                mintFlight = nil
            }
        }

        let minted: ImpulseIdentityRecord = try await requestIdentity(
            carrier: poolCarrier,
            identityToken: "",
            timeoutSeconds: ImpulseIdentityRules.mintTimeoutSeconds
        )
        guard epoch == startEpoch else {
            throw ImpulseIdentityError.discardedWhileMinting
        }

        identity = minted
        store.setString(minted.token, forKey: ImpulseIdentityRules.storageKey)
        startRenewal(of: minted, epochAtInstall: epoch)
        return minted.token
    }


    /// One connectionIdentity call. The reply must be a readable token whose exp lies in the future.
    private func requestIdentity(
        carrier: any ImpulseIdentityCarrier,
        identityToken: String,
        timeoutSeconds: Double
    ) async throws -> ImpulseIdentityRecord {
        let reply: String = try await carrier.connectionIdentity(
            identityToken: identityToken,
            apiId: apiId,
            timeoutSeconds: timeoutSeconds
        )
        guard !reply.isEmpty else {
            throw ImpulseIdentityError.emptyReply
        }

        guard let record: ImpulseIdentityRecord = ImpulseIdentityRecord.read(token: reply) else {
            throw ImpulseIdentityError.unreadableToken
        }

        guard record.claims.exp > clock.nowUnixSeconds() else {
            throw ImpulseIdentityError.expiredToken
        }

        return record
    }


    /// Installs a renewal when the renewed identity is still the one that started it.
    private func applyRenewal(
        from renewing: ImpulseIdentityRecord,
        to next: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) -> ImpulseIdentityInstall? {
        guard isCurrent(renewing, epochAtInstall: epochAtInstall) else {
            return nil
        }

        let same: Bool = ImpulseIdentityRules.isSameIdentity(before: renewing.claims, after: next.claims)
        if !same {
            epoch += 1
        }

        identity = next
        store.setString(next.token, forKey: ImpulseIdentityRules.storageKey)
        if same {
            notify(.renewed(token: next.token))
        } else {
            notify(.changed)
        }
        return ImpulseIdentityInstall(record: next, epoch: epoch)
    }


    private func startRenewal(
        of record: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) {
        renewalTask?.cancel()
        renewalTask = Task {
            await self.renewalLoop(from: record, epochAtInstall: epochAtInstall)
        }
    }


    private func expireIdentity(
        _ candidate: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) {
        guard isCurrent(candidate, epochAtInstall: epochAtInstall) else {
            return
        }

        identity = nil
        store.removeValue(forKey: ImpulseIdentityRules.storageKey)
    }


    private func discardIdentity() {
        epoch += 1
        identity = nil
        mintFlight = nil
        renewalTask?.cancel()
        renewalTask = nil
        store.removeValue(forKey: ImpulseIdentityRules.storageKey)
    }


    private func isCurrent(
        _ candidate: ImpulseIdentityRecord,
        epochAtInstall: Int
    ) -> Bool {
        return epoch == epochAtInstall && identity == candidate
    }


    private func sleepSeconds(_ seconds: Double) async -> Bool {
        do {
            try await scheduler.sleep(seconds: seconds)
            return true
        } catch {
            return false
        }
    }


    private func notify(_ event: ImpulseIdentityEvent) {
        listener?(event)
    }
}


/// The claims the client reads from a connection identity token. The signature is not checked: the server verifies it.
struct ImpulseIdentityClaims: Equatable, Sendable {
    let sub: String
    let exp: Double
    let iat: Double?
    let origIat: Double?


    /// The claims of a JWT payload, or nil when the token is not a readable JWT, has no sub, or has no positive exp.
    static func parse(token: String) -> ImpulseIdentityClaims? {
        let parts: [Substring] = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return nil
        }

        guard let payload: Data = decodeBase64Url(String(parts[1])) else {
            return nil
        }

        guard let object: Any = try? JSONSerialization.jsonObject(with: payload, options: []) else {
            return nil
        }

        guard let fields: [String: Any] = object as? [String: Any] else {
            return nil
        }

        guard let sub: String = fields["sub"] as? String else {
            return nil
        }

        guard let exp: Double = positiveNumber(fields["exp"]) else {
            return nil
        }

        return ImpulseIdentityClaims(
            sub: sub,
            exp: exp,
            iat: positiveNumber(fields["iat"]),
            origIat: positiveNumber(fields["orig_iat"])
        )
    }


    private static func positiveNumber(_ value: Any?) -> Double? {
        guard let number: NSNumber = value as? NSNumber else {
            return nil
        }

        let seconds: Double = number.doubleValue
        return seconds > 0 ? seconds : nil
    }


    private static func decodeBase64Url(_ text: String) -> Data? {
        var standard: String = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder: Int = standard.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder == 2 {
            standard += "=="
        } else if remainder == 3 {
            standard += "="
        }
        return Data(base64Encoded: standard)
    }
}


/// An identity token together with the claims read from it.
struct ImpulseIdentityRecord: Equatable, Sendable {
    let token: String
    let claims: ImpulseIdentityClaims


    /// The record of a token, or nil when the token is not readable.
    static func read(token: String) -> ImpulseIdentityRecord? {
        guard let claims: ImpulseIdentityClaims = ImpulseIdentityClaims.parse(token: token) else {
            return nil
        }

        return ImpulseIdentityRecord(token: token, claims: claims)
    }
}


/// A renewal result installed on the manager: the record now current and the epoch it was installed under.
struct ImpulseIdentityInstall: Equatable, Sendable {
    let record: ImpulseIdentityRecord
    let epoch: Int
}


/// The timing and storage constants of the connection identity, and the pure rules built on them.
enum ImpulseIdentityRules {
    static let storageKey: String = "identity_token"
    static let expiryMarginSeconds: Double = 60
    static let refreshWindowStartSeconds: Double = 300
    static let refreshWindowEndSeconds: Double = 120
    static let mintTimeoutSeconds: Double = 30
    static let renewTimeoutSeconds: Double = 30
    static let firstRetrySeconds: Double = 1
    static let maxRetrySeconds: Double = 60


    /// True while the identity is valid for more than the expiry margin.
    static func isUsable(
        _ claims: ImpulseIdentityClaims,
        nowSeconds: Double
    ) -> Bool {
        return claims.exp - nowSeconds > expiryMarginSeconds
    }


    /// The renewal point for a draw in [0, 1): uniform in [exp - 300, exp - 120], or now when the window has closed.
    static func renewalPoint(
        expSeconds: Double,
        nowSeconds: Double,
        fraction: Double
    ) -> Double {
        let endSeconds: Double = expSeconds - refreshWindowEndSeconds
        if endSeconds <= nowSeconds {
            return nowSeconds
        }

        let startSeconds: Double = max(nowSeconds, expSeconds - refreshWindowStartSeconds)
        return startSeconds + fraction * (endSeconds - startSeconds)
    }


    /// A renewal keeps sub and orig_iat and moves iat. Any other renewal is a different identity.
    static func isSameIdentity(
        before: ImpulseIdentityClaims,
        after: ImpulseIdentityClaims
    ) -> Bool {
        guard let origIat: Double = after.origIat else {
            return false
        }

        return before.sub == after.sub && before.origIat == after.origIat && origIat != after.iat
    }
}
