import Foundation


/// The credential the update socket presents now: the access token with a session, else the connection identity.
public protocol ImpulseConnectionCredentials: Sendable {
    /// The credential, or nil when none is known yet. It never sends anything.
    func currentCredential() -> String?
}


/// What a declaration attempt ended with. Only the outcome is reported, never a value.
public enum ImpulseDeclarationOutcome: String, Equatable, Sendable {
    case ok
    case retry
    case gaveUp = "gave_up"
    case sessionLost = "session_lost"
}


/// Receives the outcome of each attempt: the outcome, the attempt number, and the RPC error code or 0.
public typealias ImpulseDeclarationReporter = @Sendable (ImpulseDeclarationOutcome, Int, Int) -> Void


/// Tells the server what the application, the device and the languages are: the initConnection declaration.
///
/// The declaration is keyed by the credential the update socket presents and by the declaration itself. It goes out when
/// either changes (a new credential, a session, a language switch), never without a credential, and never twice for the
/// same pair. A failed attempt is retried after the request policy's wait, for at most `maxAttempts` attempts in a run,
/// and is then dropped until the next trigger. `awaitDeclared` ends when the pair is declared, when a run ends without
/// declaring it, or when its timeout passes.
public actor ImpulseConnectionDeclarer: ImpulseDeclarationGate {
    /// The attempts of one run, the first one included.
    public static let maxAttempts: Int = 3

    private struct Waiter {
        let runsAtStart: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        let timer: Task<Void, Never>
    }


    private let carrier: any ImpulseRequestCarrier
    private let credentials: any ImpulseConnectionCredentials
    private let clock: any ImpulseRequestClock
    private let reporter: ImpulseDeclarationReporter?
    private var declaration: ImpulseDeclaration? = nil
    private var earlyLangCode: String? = nil
    private var earlySystemLangCode: String? = nil
    private var sentKey: ImpulseDeclarationKey? = nil
    private var running: Bool = false
    private var rerun: Bool = false
    private var generation: UInt64 = 0
    private var finishedRuns: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]


    /// Creates the declarer. `carrier` is the update socket carrier, which sends the declaration on the connection.
    public init(
        carrier: any ImpulseRequestCarrier,
        credentials: any ImpulseConnectionCredentials,
        clock: any ImpulseRequestClock = ImpulseSystemRequestClock(),
        reporter: ImpulseDeclarationReporter? = nil
    ) {
        self.carrier = carrier
        self.credentials = credentials
        self.clock = clock
        self.reporter = reporter
    }


    /// Sets the whole declaration, at start-up. A language set before it arrived is newer than the one inside it.
    public func setDeclaration(_ value: ImpulseDeclaration) {
        var result: ImpulseDeclaration = value
        if let langCode: String = self.earlyLangCode {
            result = result.withLangCode(langCode)
            self.earlyLangCode = nil
        }
        if let systemLangCode: String = self.earlySystemLangCode {
            result = result.withSystemLangCode(systemLangCode)
            self.earlySystemLangCode = nil
        }
        self.declaration = result
        self.trigger()
    }


    /// Sets the current language. Before the declaration is set, the language is kept for it.
    public func setLangCode(_ langCode: String) {
        guard let current: ImpulseDeclaration = self.declaration else {
            self.earlyLangCode = langCode
            return
        }
        self.declaration = current.withLangCode(langCode)
        self.trigger()
    }


    /// Sets the system language. Before the declaration is set, the language is kept for it.
    public func setSystemLangCode(_ langCode: String) {
        guard let current: ImpulseDeclaration = self.declaration else {
            self.earlySystemLangCode = langCode
            return
        }
        self.declaration = current.withSystemLangCode(langCode)
        self.trigger()
    }


    /// The session was established or its tokens were replaced.
    public func sessionChanged() {
        self.trigger()
    }


    /// The socket now presents another credential: a new identity, or a sign-out or sign-in.
    public func credentialChanged() {
        self.trigger()
    }


    /// The server lost the declaration (`CONNECTION_NOT_INITED`): the sent pair is forgotten and declared again.
    public func invalidate() async {
        self.sentKey = nil
        self.notifyWaiters()
        self.trigger()
    }


    /// Waits until the current pair is declared, at most `timeoutSeconds`. True when it is. A run in flight is waited for,
    /// and a wait that finds nothing running starts one.
    public func awaitDeclared(timeoutSeconds: TimeInterval) async -> Bool {
        if self.isDeclared(credential: self.credentials.currentCredential()) {
            return true
        }
        if !self.running {
            self.trigger()
        }
        let identifier: UUID = UUID()
        let runsAtStart: UInt64 = self.finishedRuns
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
            let timer: Task<Void, Never> = Task {
                try? await Task.sleep(nanoseconds: ImpulseConnectionDeclarer.nanoseconds(seconds: timeoutSeconds))
                await self.expireWaiter(identifier: identifier)
            }
            self.waiters[identifier] = Waiter(
                runsAtStart: runsAtStart,
                continuation: continuation,
                timer: timer
            )
        }
    }


    private static func nanoseconds(seconds: TimeInterval) -> UInt64 {
        return UInt64(max(seconds, 0) * 1_000_000_000.0)
    }


    /// Starts a run unless one is in flight, in which case the run is repeated once it ends.
    private func trigger() {
        self.generation += 1
        if self.running {
            self.rerun = true
            return
        }
        self.running = true
        let started: UInt64 = self.generation
        Task {
            await self.runAttempt(attempt: 1, forGeneration: started)
        }
    }


    /// Starts a run that a trigger asked for while the last one was in flight.
    private func restartIfTriggered() {
        if !self.rerun || self.running {
            return
        }
        self.rerun = false
        self.running = true
        let started: UInt64 = self.generation
        Task {
            await self.runAttempt(attempt: 1, forGeneration: started)
        }
    }


    /// Ends a run that did not retry.
    private func finish() {
        self.running = false
        self.finishedRuns += 1
        self.notifyWaiters()
        self.restartIfTriggered()
    }


    /// Runs a scheduled retry unless a newer trigger has taken over.
    private func runRetry(attempt: Int, forGeneration: UInt64) async {
        if self.generation != forGeneration || self.running {
            return
        }
        self.running = true
        await self.runAttempt(attempt: attempt, forGeneration: forGeneration)
    }


    /// One attempt: sends the declaration of the current pair unless it is declared already.
    private func runAttempt(
        attempt: Int,
        forGeneration: UInt64
    ) async {
        guard let presented: String = self.credentials.currentCredential(), let current: ImpulseDeclaration = self.declaration else {
            self.finish()
            return
        }
        if self.isDeclared(credential: presented) {
            self.finish()
            return
        }

        let result: Result<[UInt8], ImpulseCarrierFailure> = await self.carrier.send(
            method: ImpulseDeclaration.initConnectionMethod,
            data: current.initConnectionRequest(),
            timeoutSeconds: ImpulseRequestTimeouts.updateCallSeconds
        )
        switch result {
        case .success:
            self.sentKey = ImpulseDeclarationKey(credential: presented, declaration: current)
            self.notifyWaiters()
            self.report(.ok, attempt: attempt, code: 0)
            self.finish()

        case .failure(let failure):
            self.failed(attempt: attempt, forGeneration: forGeneration, failure: failure)
        }
    }


    /// Decides what a failed attempt does: end the run, or schedule the next attempt after the wait.
    private func failed(
        attempt: Int,
        forGeneration: UInt64,
        failure: ImpulseCarrierFailure
    ) {
        let error: ImpulseRpcError? = ImpulseCarrier.rpcError(from: failure, route: .update)
        let code: Int = error?.code ?? 0
        switch self.decision(error: error, attempt: attempt) {
        case .authorizationRequired:
            self.report(.sessionLost, attempt: attempt, code: code)
            self.finish()

        case .deliver:
            self.report(.gaveUp, attempt: attempt, code: code)
            self.finish()

        case .retryAfter(let seconds):
            if attempt >= ImpulseConnectionDeclarer.maxAttempts {
                self.report(.gaveUp, attempt: attempt, code: code)
                self.finish()
                return
            }
            self.running = false
            self.finishedRuns += 1
            self.notifyWaiters()
            self.scheduleRetry(attempt: attempt + 1, forGeneration: forGeneration, seconds: seconds)
            self.report(.retry, attempt: attempt, code: code)
            self.restartIfTriggered()
        }
    }


    private func decision(
        error: ImpulseRpcError?,
        attempt: Int
    ) -> ImpulseRequestDecision {
        guard let error: ImpulseRpcError = error else {
            return .retryAfter(seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: attempt))
        }
        return ImpulseRequestPolicy.decide(
            error: error,
            options: ImpulseRequestOptions(),
            failureCount: attempt
        )
    }


    private func scheduleRetry(
        attempt: Int,
        forGeneration: UInt64,
        seconds: TimeInterval
    ) {
        Task {
            _ = try? await self.clock.sleep(seconds: seconds)
            await self.runRetry(attempt: attempt, forGeneration: forGeneration)
        }
    }


    private func report(
        _ outcome: ImpulseDeclarationOutcome,
        attempt: Int,
        code: Int
    ) {
        self.reporter?(outcome, attempt, code)
    }


    private func isDeclared(credential: String?) -> Bool {
        guard let presented: String = credential else {
            return false
        }
        guard let current: ImpulseDeclaration = self.declaration, let sent: ImpulseDeclarationKey = self.sentKey else {
            return false
        }
        return sent.credential == presented && sent.declaration == current
    }


    /// Releases the waiters that the state now settles: all of them when the pair is declared, and those whose run ended
    /// without declaring it when no run is pending.
    private func notifyWaiters() {
        let declared: Bool = self.isDeclared(credential: self.credentials.currentCredential())
        var resolutions: [(identifier: UUID, declared: Bool)] = []
        for (identifier, waiter) in self.waiters {
            if declared {
                resolutions.append((identifier: identifier, declared: true))
            } else if self.finishedRuns != waiter.runsAtStart && !self.running && !self.rerun {
                resolutions.append((identifier: identifier, declared: false))
            }
        }
        for resolution: (identifier: UUID, declared: Bool) in resolutions {
            self.resolveWaiter(identifier: resolution.identifier, declared: resolution.declared)
        }
    }


    private func expireWaiter(identifier: UUID) async {
        self.resolveWaiter(identifier: identifier, declared: false)
    }


    private func resolveWaiter(
        identifier: UUID,
        declared: Bool
    ) {
        guard let waiter: Waiter = self.waiters.removeValue(forKey: identifier) else {
            return
        }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: declared)
    }
}
