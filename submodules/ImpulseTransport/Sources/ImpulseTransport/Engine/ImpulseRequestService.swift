import Foundation


/// The deadlines of the requests, in seconds.
public enum ImpulseRequestTimeouts {
    /// The deadline of a call on the update socket and on the pool.
    public static let updateCallSeconds: TimeInterval = 30
    /// The deadline of a media call.
    public static let mediaCallSeconds: TimeInterval = 10
    /// How long a call waits for its connection to be declared before it is sent anyway.
    public static let declarationWaitSeconds: TimeInterval = 10
    /// The time a blocking call waits beyond its call deadline for the settle.
    public static let blockingGraceSeconds: TimeInterval = 5


    /// The deadline of a call on a route. A refused route is never sent, so it has no deadline.
    public static func callSeconds(route: ImpulseCarrierRoute) -> TimeInterval {
        switch route {
        case .update, .pool:
            return ImpulseRequestTimeouts.updateCallSeconds

        case .media:
            return ImpulseRequestTimeouts.mediaCallSeconds

        case .refused:
            return 0
        }
    }


    /// The longest time a blocking call waits for its settle: the call deadline plus the grace.
    public static func blockingWaitSeconds(callSeconds: TimeInterval) -> TimeInterval {
        return callSeconds + ImpulseRequestTimeouts.blockingGraceSeconds
    }
}


/// The options a request is sent with. The defaults are the canonical ones: server errors are retried and a flood
/// wait is waited out.
public struct ImpulseRequestOptions: Equatable, Sendable {
    /// The request may be sent without a logged-in user.
    public let withoutLogin: Bool
    /// Server errors are delivered at once instead of retried.
    public let failOnServerErrors: Bool
    /// Flood waits are retried even when server errors are not.
    public let failOnServerErrorsExceptFloodWait: Bool
    /// Flood waits are delivered at once instead of waited out.
    public let doNotWaitFloodWait: Bool
    /// The longest time the call may take, in seconds, counted from when the call is ready to be sent, after any wait
    /// for a login. Nil means no total deadline: the call retries until it gets a reply, the same as the Android client.
    /// Once the deadline passes, no further send or wait starts, and a send in flight is cut to the time left.
    public let totalDeadlineSeconds: TimeInterval?
    /// A download gives up after 10 network failures instead of 6. Only the download methods have a limit.
    public let forceDownload: Bool


    public init(
        withoutLogin: Bool = false,
        failOnServerErrors: Bool = false,
        failOnServerErrorsExceptFloodWait: Bool = false,
        doNotWaitFloodWait: Bool = false,
        totalDeadlineSeconds: TimeInterval? = nil,
        forceDownload: Bool = false
    ) {
        self.withoutLogin = withoutLogin
        self.failOnServerErrors = failOnServerErrors
        self.failOnServerErrorsExceptFloodWait = failOnServerErrorsExceptFloodWait
        self.doNotWaitFloodWait = doNotWaitFloodWait
        self.totalDeadlineSeconds = totalDeadlineSeconds
        self.forceDownload = forceDownload
    }
}


/// What the service does with one failed reply.
public enum ImpulseRequestDecision: Equatable, Sendable {
    /// The error is delivered to the caller.
    case deliver
    /// The request is sent again after the wait. Zero means at once.
    case retryAfter(seconds: TimeInterval)
    /// The error is delivered, and the session is reported as needing authorization again.
    case authorizationRequired
}


/// Why a request did not produce a reply.
public enum ImpulseRequestFailure: Error, Equatable, Sendable {
    /// The server answered with an error, or the request was refused locally.
    case rpc(ImpulseRpcError)
    /// The carrier failed without a server answer, such as a lost connection or a timeout.
    case network(ImpulseCarrierFailure)
    /// The request was cancelled before it produced a reply.
    case canceled
    /// The route epoch advanced while the call was in flight. The service retries such a call without spending its
    /// budget, so this failure is never delivered to the caller.
    case routeChanged
}


/// The retry and delivery rules of a request, as pure functions.
public enum ImpulseRequestPolicy {
    /// The wait of a flood wait that carries no number.
    public static let defaultFloodWaitSeconds: TimeInterval = 2
    /// The largest wait of a server error retry.
    public static let maxServerBackoffSeconds: TimeInterval = 10
    /// The media methods that download a file. Only these give up after a run of network failures.
    public static let downloadMethods: Set<String> = [
        "upload.getFile",
        "upload.getWebFile",
    ]

    private static let downloadRetryMax: Int = 6
    private static let forceDownloadRetryMax: Int = 10
    private static let retryLimitCode: Int = -123
    private static let retryLimitText: String = "RETRY_LIMIT"
    private static let floodWaitCode: Int = 420
    private static let authorizationCode: Int = 401
    private static let badRequestCode: Int = 400
    private static let serverErrorCode: Int = 500
    private static let serviceUnavailableCode: Int = 503
    private static let sessionPasswordNeededText: String = "SESSION_PASSWORD_NEEDED"
    private static let authRestartText: String = "AUTH_RESTART"
    private static let workerBusyText: String = "WORKER_BUSY_TOO_LONG_RETRY"
    private static let msgWaitFailedText: String = "MSG_WAIT_FAILED"
    private static let msgWaitTimeoutText: String = "MSG_WAIT_TIMEOUT"
    private static let storyFloodText: String = "STORY_SEND_FLOOD"
    private static let slowmodeWaitText: String = "SLOWMODE_WAIT_"


    /// True when a request that needs a user waits for a login: `loggedIn` (the login gate, open when a user is logged in)
    /// is closed and the request is not marked as usable without one.
    public static func mustWaitForLogin(
        options: ImpulseRequestOptions,
        loggedIn: Bool
    ) -> Bool {
        return !loggedIn && !options.withoutLogin
    }


    /// The decision for one failed reply. `failureCount` counts the failures of the request, this one included.
    public static func decide(
        error: ImpulseRpcError,
        options: ImpulseRequestOptions,
        failureCount: Int
    ) -> ImpulseRequestDecision {
        let text: String = error.text

        if error.code == ImpulseRequestPolicy.authorizationCode && text != ImpulseRequestPolicy.sessionPasswordNeededText {
            return .authorizationRequired
        }

        let processEvenFailed: Bool = error.code == ImpulseRequestPolicy.serverErrorCode
            && text.contains(ImpulseRequestPolicy.authRestartText)
        let retriesServerErrors: Bool = !options.failOnServerErrors || processEvenFailed

        let isServerFailure: Bool = error.code == ImpulseRequestPolicy.serverErrorCode
            || error.code == ImpulseRequestPolicy.serviceUnavailableCode
            || error.code < 0
        if retriesServerErrors && isServerFailure {
            let isWorkerBusy: Bool = error.code == ImpulseRequestPolicy.serverErrorCode
                && text.contains(ImpulseRequestPolicy.workerBusyText)
            if text.contains(ImpulseRequestPolicy.msgWaitFailedText) || isWorkerBusy {
                return .retryAfter(seconds: 0)
            }
            let backoff: TimeInterval = min(TimeInterval(max(failureCount, 0)), ImpulseRequestPolicy.maxServerBackoffSeconds)
            return .retryAfter(seconds: backoff)
        }

        let floodRetryAllowed: Bool = retriesServerErrors || options.failOnServerErrorsExceptFloodWait
        if floodRetryAllowed
            && error.code == ImpulseRequestPolicy.floodWaitCode
            && !options.doNotWaitFloodWait
            && !text.contains(ImpulseRequestPolicy.storyFloodText) {
            if text.contains(ImpulseRequestPolicy.slowmodeWaitText) {
                return .deliver
            }
            if let seconds: Int = ImpulseErrors.floodWaitSeconds(error) {
                return .retryAfter(seconds: TimeInterval(seconds))
            }
            return .retryAfter(seconds: ImpulseRequestPolicy.defaultFloodWaitSeconds)
        }

        if retriesServerErrors
            && error.code == ImpulseRequestPolicy.badRequestCode
            && (text.contains(ImpulseRequestPolicy.msgWaitTimeoutText) || text.contains(ImpulseRequestPolicy.msgWaitFailedText)) {
            return .retryAfter(seconds: 0)
        }

        return .deliver
    }


    /// The wait before the send that follows a network failure. `attempt` counts the failures of the request from 1,
    /// so the wait grows by one second per failure up to the largest server backoff.
    public static func networkFailureSeconds(attempt: Int) -> TimeInterval {
        return min(TimeInterval(max(attempt, 1)), ImpulseRequestPolicy.maxServerBackoffSeconds)
    }


    /// The error a download ends with once its network failures reach the retry limit: 6 failures, or 10 with
    /// `forceDownload`. Nil while the call goes on, and always nil for a method that is not a download. `attempt`
    /// counts the network failures of the request from 1, this one included.
    public static func downloadRetryLimit(
        method: String,
        options: ImpulseRequestOptions,
        attempt: Int
    ) -> ImpulseRpcError? {
        guard ImpulseRequestPolicy.downloadMethods.contains(method) else {
            return nil
        }

        let limit: Int = options.forceDownload
            ? ImpulseRequestPolicy.forceDownloadRetryMax
            : ImpulseRequestPolicy.downloadRetryMax
        if attempt < limit {
            return nil
        }

        return ImpulseRpcError(
            code: ImpulseRequestPolicy.retryLimitCode,
            text: ImpulseRequestPolicy.retryLimitText,
            temporary: false
        )
    }


    /// The failure of a call that ended with a carrier error and no server answer. When the route epoch advanced while the
    /// call was in flight (`epochAdvanced`), the failure is `routeChanged`, whatever the error is: the classification is by
    /// the epoch, not by the error type. Otherwise it is the carrier failure of the error.
    public static func failure(
        for error: Error,
        epochAdvanced: Bool
    ) -> ImpulseRequestFailure {
        if epochAdvanced {
            return .routeChanged
        }
        return .network(ImpulseRequestPolicy.carrierFailure(from: error))
    }


    /// The carrier failure of any error a carrier or a fleet reports. A carrier failure keeps its codes; a media or pool
    /// failure maps through its carrier; any other error maps through the SDK failure mapping.
    private static func carrierFailure(from error: Error) -> ImpulseCarrierFailure {
        if let carrierResult: ImpulseCarrierFailure = error as? ImpulseCarrierFailure {
            return carrierResult
        }

        if let mediaFailure: ImpulseMediaFailure = error as? ImpulseMediaFailure {
            return ImpulseMediaRequestCarrier.carrierFailure(from: mediaFailure)
        }

        if let poolFailure: ImpulsePoolFailure = error as? ImpulsePoolFailure {
            return ImpulsePoolRequestCarrier.carrierFailure(from: poolFailure)
        }

        return ImpulseSdkFailure.carrierFailure(from: error)
    }
}


/// The time and the waits of the request service. The app uses `ImpulseSystemRequestClock`; tests inject a fake clock
/// so that no retry or deadline waits in real time.
public protocol ImpulseRequestClock: Sendable {
    /// The current time in seconds. Only the difference between two readings is meaningful.
    func nowSeconds() -> TimeInterval

    /// Waits for `seconds`. Throws when the waiting task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}


/// The monotonic system time and a real sleep.
public struct ImpulseSystemRequestClock: ImpulseRequestClock {
    public init() {
    }


    public func nowSeconds() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }


    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}


/// The session the requests read: whether one is stored, when its access token needs a refresh, and the refresh.
/// `ImpulseTokens` is the session of the app.
public protocol ImpulseRequestSession: Sendable {
    func hasSession() async -> Bool

    func needsProactiveRefresh() async -> Bool

    /// Refreshes the session. A throw keeps the session.
    func refresh() async throws -> ImpulseRefreshOutcome
}


/// Sends one call over one carrier. The completion of the call is the returned result, and the deadline is the one asked.
public protocol ImpulseRequestCarrier: Sendable {
    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure>
}


/// Declares the connection to the server before its calls are sent. The app supplies it.
public protocol ImpulseDeclarationGate: Sendable {
    /// Waits until the connection is declared, at most `timeoutSeconds`. True when it is.
    func awaitDeclared(timeoutSeconds: TimeInterval) async -> Bool

    /// The server lost the declaration (`CONNECTION_NOT_INITED`): the next call declares it again.
    func invalidate() async
}


/// A request that was submitted. Its result settles once, with the reply bytes or the failure.
public struct ImpulseRequestCall: Sendable {
    public let result: Task<Result<[UInt8], ImpulseRequestFailure>, Never>


    public init(result: Task<Result<[UInt8], ImpulseRequestFailure>, Never>) {
        self.result = result
    }


    /// Stops the request. It settles as canceled unless the reply already arrived.
    public func cancel() {
        self.result.cancel()
    }
}


extension ImpulseTokens: ImpulseRequestSession {
}


/// Holds the requests that wait for a login. It opens when a user logs in and closes when the session ends. One gate is
/// shared by the request services of an account, so a login releases the requests of every session of that account.
public final class ImpulseLoginGate: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var isOpen: Bool
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]


    public init(isOpen: Bool) {
        self.isOpen = isOpen
    }


    /// Opens the gate, which releases the waiting requests, or closes it.
    public func setOpen(_ value: Bool) {
        var released: [CheckedContinuation<Bool, Never>] = []
        self.lock.lock()
        self.isOpen = value
        if value {
            released = Array(self.waiters.values)
            self.waiters.removeAll()
        }
        self.lock.unlock()

        for continuation: CheckedContinuation<Bool, Never> in released {
            continuation.resume(returning: true)
        }
    }


    /// True while the gate is open. The gate is the login state of the requests: a request that needs a login waits while
    /// it is closed, even when a session is stored, because the tokens are stored before the socket is rekeyed and the gate opens.
    internal var isOpenNow: Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.isOpen
    }


    /// Returns true once the gate is open, and false when the waiting task is cancelled first.
    internal func wait() async -> Bool {
        let identifier: UUID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) -> Void in
                self.lock.lock()
                if self.isOpen {
                    self.lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                self.waiters[identifier] = continuation
                self.lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            let continuation: CheckedContinuation<Bool, Never>? = self.waiters.removeValue(forKey: identifier)
            self.lock.unlock()
            continuation?.resume(returning: false)
        }
    }
}


/// The route epoch of the service. The route owner advances it once per route change. A send stamps the epoch it runs
/// under, and a failure of a send stamped with an older epoch is a route failure.
internal final class ImpulseRouteEpochCounter: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var epoch: Int = 0


    internal func advance() {
        self.lock.lock()
        self.epoch += 1
        self.lock.unlock()
    }


    internal func current() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.epoch
    }
}


/// Sends the requests of a connection. It chooses the carrier of each method, waits for a login when the request
/// needs one, declares the connection, retries flood waits, server errors and network failures, refreshes a refused
/// token once, and reports a 401 as an authorization failure. Requests submitted with a predecessor run after it has settled.
public final class ImpulseRequestService: Sendable {
    private let session: any ImpulseRequestSession
    private let updateCarrier: any ImpulseRequestCarrier
    private let mediaCarrier: any ImpulseRequestCarrier
    private let poolCarrier: any ImpulseRequestCarrier
    private let declarations: (any ImpulseDeclarationGate)?
    private let loginGate: ImpulseLoginGate
    private let routeEpoch: ImpulseRouteEpochCounter
    private let onAuthorizationRequired: @Sendable () -> Void
    private let clock: any ImpulseRequestClock
    private let identityTag: (@Sendable () async -> String?)?
    private static let notInitializedText: String = "CONNECTION_NOT_INITED"
    /// The failure a call ends with when its deadline passes before any carrier failure. It has no server answer, so
    /// it is a timeout, the same as a carrier failure without a code.
    private static let deadlineFailure: ImpulseCarrierFailure = ImpulseCarrierFailure(
        sdkCode: 0,
        appCode: 0,
        appType: "",
        metadata: [:]
    )


    /// What a token refresh ended with: a fresh session, a refresh that did not renew the session, or a refresh that
    /// failed on the network.
    private enum RefreshStep {
        case refreshed
        case notRefreshed
        case faulted
    }


    /// Creates the service. `signedIn` is the login state at creation; `onAuthorizationRequired` runs when a request
    /// of a signed-in connection ends with a 401 other than `SESSION_PASSWORD_NEEDED`. `clock` times the waits and the
    /// total deadlines of the calls.
    public init(
        session: any ImpulseRequestSession,
        updateCarrier: any ImpulseRequestCarrier,
        mediaCarrier: any ImpulseRequestCarrier,
        poolCarrier: any ImpulseRequestCarrier,
        declarations: (any ImpulseDeclarationGate)?,
        signedIn: Bool,
        onAuthorizationRequired: @escaping @Sendable () -> Void,
        clock: any ImpulseRequestClock = ImpulseSystemRequestClock(),
        loginGate: ImpulseLoginGate? = nil,
        identityTag: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        self.updateCarrier = updateCarrier
        self.mediaCarrier = mediaCarrier
        self.poolCarrier = poolCarrier
        self.declarations = declarations
        self.loginGate = loginGate ?? ImpulseLoginGate(isOpen: signedIn)
        self.routeEpoch = ImpulseRouteEpochCounter()
        self.onAuthorizationRequired = onAuthorizationRequired
        self.clock = clock
        self.identityTag = identityTag
    }


    /// Reports a login or a session end. A login releases the requests that wait for one.
    public func setSignedIn(_ signedIn: Bool) {
        self.loginGate.setOpen(signedIn)
    }


    /// Advances the route epoch. The route owner calls it once per route change, before it reconnects over the new route.
    /// A call that sent under the older epoch and fails after the advance is a route failure: it does not spend its
    /// budget, it waits the policy delay for its attempt number (never zero), and its next send takes the current epoch.
    public func advanceRouteEpoch() {
        self.routeEpoch.advance()
    }


    /// Submits a request. With a predecessor, the request is sent only after the predecessor has settled.
    public func submit(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions,
        dependsOn predecessor: ImpulseRequestCall? = nil
    ) -> ImpulseRequestCall {
        let task: Task<Result<[UInt8], ImpulseRequestFailure>, Never> = Task {
            if let previous: ImpulseRequestCall = predecessor {
                _ = await previous.result.value
            }
            return await self.execute(request: request, options: options)
        }
        return ImpulseRequestCall(result: task)
    }


    /// Sends an encoded request and settles with its reply bytes or its failure. The caller decodes the reply.
    public func execute(
        request: ImpulseEncodedRequest,
        options: ImpulseRequestOptions
    ) async -> Result<[UInt8], ImpulseRequestFailure> {
        if ImpulseRequestPolicy.mustWaitForLogin(options: options, loggedIn: self.loginGate.isOpenNow) {
            let released: Bool = await self.loginGate.wait()
            if !released {
                return .failure(.canceled)
            }
        }
        let signedIn: Bool = await self.session.hasSession()

        let route: ImpulseCarrierRoute = ImpulseCarrier.route(method: request.method, signedIn: signedIn)
        if case .refused(let refusal) = route {
            ImpulseDiagnostics.log("A call is refused locally: \(request.method), signed in: \(signedIn)")
            return .failure(.rpc(refusal))
        }
        if !signedIn, ImpulseMethodClasses.identitySocketMethods.contains(request.method), let tagOf: (@Sendable () async -> String?) = self.identityTag {
            let tag: String? = await tagOf()
            ImpulseDiagnostics.log("A call goes on the identity: \(request.method), identity \(tag ?? "none")")
        }
        if Task.isCancelled {
            return .failure(.canceled)
        }

        let deadline: TimeInterval? = options.totalDeadlineSeconds.map { (seconds: TimeInterval) -> TimeInterval in
            return self.clock.nowSeconds() + seconds
        }
        var refreshDue: Bool = true
        var declarationAwaited: Bool = false
        var refreshAttempted: Bool = false
        var redeclared: Bool = false
        var failureCount: Int = 0
        var networkAttempt: Int = 1
        var lastFailure: ImpulseCarrierFailure = ImpulseRequestService.deadlineFailure
        while true {
            if Task.isCancelled {
                return .failure(.canceled)
            }

            if refreshDue {
                refreshDue = false
                if signedIn {
                    let needsRefresh: Bool = await self.session.needsProactiveRefresh()
                    if needsRefresh {
                        let step: RefreshStep = await self.refreshStep()
                        switch step {
                        case .refreshed:
                            break

                        case .notRefreshed:
                            return .failure(.rpc(ImpulseRpcError(code: 401, text: "SESSION_EXPIRED", temporary: false)))

                        case .faulted:
                            if let ended: ImpulseRequestFailure = await self.waitAfterNetworkFailure(
                                method: request.method,
                                options: options,
                                attempt: networkAttempt,
                                deadline: deadline,
                                failure: lastFailure
                            ) {
                                return .failure(ended)
                            }
                            networkAttempt += 1
                            refreshDue = true
                            continue
                        }
                    }
                }
            }

            if !declarationAwaited {
                declarationAwaited = true
                if let gate: any ImpulseDeclarationGate = self.declarations {
                    _ = await gate.awaitDeclared(timeoutSeconds: ImpulseRequestTimeouts.declarationWaitSeconds)
                }
            }

            let timeoutSeconds: TimeInterval = self.sendTimeout(route: route, deadline: deadline)
            if timeoutSeconds <= 0 {
                return .failure(.network(lastFailure))
            }

            let sendEpoch: Int = self.routeEpoch.current()
            let settled: Result<[UInt8], ImpulseCarrierFailure> = await self.sendOnce(
                request: request,
                route: route,
                timeoutSeconds: timeoutSeconds
            )
            switch settled {
            case .success(let reply):
                return .success(reply)

            case .failure(let failure):
                if ImpulseErrors.isCancelled(failure) {
                    return .failure(.canceled)
                }
                guard let error: ImpulseRpcError = ImpulseCarrier.rpcError(from: failure, route: route) else {
                    lastFailure = failure
                    let transitionFailure: ImpulseRequestFailure = ImpulseRequestPolicy.failure(
                        for: failure,
                        epochAdvanced: self.routeEpoch.current() != sendEpoch
                    )
                    if case .routeChanged = transitionFailure {
                        if let ended: ImpulseRequestFailure = await self.waitBeforeAttempt(
                            seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: networkAttempt),
                            deadline: deadline,
                            endingWith: .network(failure)
                        ) {
                            return .failure(ended)
                        }
                        refreshDue = true
                        continue
                    }
                    if let ended: ImpulseRequestFailure = await self.waitAfterNetworkFailure(
                        method: request.method,
                        options: options,
                        attempt: networkAttempt,
                        deadline: deadline,
                        failure: failure
                    ) {
                        return .failure(ended)
                    }
                    networkAttempt += 1
                    refreshDue = true
                    continue
                }

                if error.text == ImpulseRequestService.notInitializedText, !redeclared, let gate: any ImpulseDeclarationGate = self.declarations {
                    redeclared = true
                    await gate.invalidate()
                    _ = await gate.awaitDeclared(timeoutSeconds: ImpulseRequestTimeouts.declarationWaitSeconds)
                    continue
                }

                let refusedToken: Bool = ImpulseErrors.isTokenRefusal(failure)
                    || ImpulseErrors.classify(error) == .refreshAndRetry
                if refusedToken && signedIn && !refreshAttempted {
                    let step: RefreshStep = await self.refreshStep()
                    switch step {
                    case .refreshed:
                        refreshAttempted = true
                        continue

                    case .notRefreshed:
                        refreshAttempted = true

                    case .faulted:
                        if let ended: ImpulseRequestFailure = await self.waitAfterNetworkFailure(
                            method: request.method,
                            options: options,
                            attempt: networkAttempt,
                            deadline: deadline,
                            failure: lastFailure
                        ) {
                            return .failure(ended)
                        }
                        networkAttempt += 1
                        refreshDue = true
                        continue
                    }
                }

                let decision: ImpulseRequestDecision = ImpulseRequestPolicy.decide(
                    error: error,
                    options: options,
                    failureCount: failureCount + 1
                )
                switch decision {
                case .deliver:
                    return .failure(.rpc(error))

                case .authorizationRequired:
                    if signedIn {
                        self.onAuthorizationRequired()
                    }
                    return .failure(.rpc(error))

                case .retryAfter(let seconds):
                    failureCount += 1
                    if let ended: ImpulseRequestFailure = await self.waitBeforeAttempt(
                        seconds: seconds,
                        deadline: deadline,
                        endingWith: .rpc(error)
                    ) {
                        return .failure(ended)
                    }
                }
            }
        }
    }


    /// The time a send may take: the call deadline, or the time left before the total deadline when that is shorter.
    /// Zero or less means the deadline has passed.
    private func sendTimeout(
        route: ImpulseCarrierRoute,
        deadline: TimeInterval?
    ) -> TimeInterval {
        let callSeconds: TimeInterval = ImpulseRequestTimeouts.callSeconds(route: route)
        guard let end: TimeInterval = deadline else {
            return callSeconds
        }
        return min(callSeconds, end - self.clock.nowSeconds())
    }


    private func sendOnce(
        request: ImpulseEncodedRequest,
        route: ImpulseCarrierRoute,
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let carrier: any ImpulseRequestCarrier
        switch route {
        case .update:
            carrier = self.updateCarrier

        case .media:
            carrier = self.mediaCarrier

        case .pool:
            carrier = self.poolCarrier

        case .refused:
            return .failure(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
        }

        return await carrier.send(
            method: request.method,
            data: request.proto,
            timeoutSeconds: timeoutSeconds
        )
    }


    /// Refreshes the session. A throw is a failure of the refresh on the network: the session is kept and the
    /// refresh is not a session end.
    private func refreshStep() async -> RefreshStep {
        do {
            let outcome: ImpulseRefreshOutcome = try await self.session.refresh()
            if outcome == .refreshed {
                return .refreshed
            }
            return .notRefreshed
        } catch {
            return .faulted
        }
    }


    /// Waits after a network failure. A download that reaches its retry limit ends with `-123 RETRY_LIMIT` before any
    /// wait. Otherwise the wait is the one of `waitBeforeAttempt`, which ends the call with `failure` when the deadline
    /// passes during it.
    private func waitAfterNetworkFailure(
        method: String,
        options: ImpulseRequestOptions,
        attempt: Int,
        deadline: TimeInterval?,
        failure: ImpulseCarrierFailure
    ) async -> ImpulseRequestFailure? {
        if let limit: ImpulseRpcError = ImpulseRequestPolicy.downloadRetryLimit(
            method: method,
            options: options,
            attempt: attempt
        ) {
            return .rpc(limit)
        }

        return await self.waitBeforeAttempt(
            seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: attempt),
            deadline: deadline,
            endingWith: .network(failure)
        )
    }


    /// Waits before the next attempt. Nil when the call goes on. Otherwise it is the failure that ends the call: `canceled`
    /// when the task was cancelled during the wait, or `endingWith` when the deadline passed during it. The wait is cut
    /// at the deadline, so no wait runs past it.
    private func waitBeforeAttempt(
        seconds: TimeInterval,
        deadline: TimeInterval?,
        endingWith: ImpulseRequestFailure
    ) async -> ImpulseRequestFailure? {
        var wait: TimeInterval = seconds
        if let end: TimeInterval = deadline {
            wait = min(seconds, end - self.clock.nowSeconds())
        }
        if wait > 0 {
            do {
                try await self.clock.sleep(seconds: wait)
            } catch {
                return .canceled
            }
        }

        if Task.isCancelled {
            return .canceled
        }
        if let end: TimeInterval = deadline, self.clock.nowSeconds() >= end {
            return endingWith
        }
        return nil
    }
}
