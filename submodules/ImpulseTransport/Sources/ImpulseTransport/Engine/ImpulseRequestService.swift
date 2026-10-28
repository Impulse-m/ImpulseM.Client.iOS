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


    public init(
        withoutLogin: Bool = false,
        failOnServerErrors: Bool = false,
        failOnServerErrorsExceptFloodWait: Bool = false,
        doNotWaitFloodWait: Bool = false
    ) {
        self.withoutLogin = withoutLogin
        self.failOnServerErrors = failOnServerErrors
        self.failOnServerErrorsExceptFloodWait = failOnServerErrorsExceptFloodWait
        self.doNotWaitFloodWait = doNotWaitFloodWait
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
}


/// The retry and delivery rules of a request, as pure functions.
public enum ImpulseRequestPolicy {
    /// The wait of a flood wait that carries no number.
    public static let defaultFloodWaitSeconds: TimeInterval = 2
    /// The largest wait of a server error retry.
    public static let maxServerBackoffSeconds: TimeInterval = 10

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


    /// True when a request that needs a user waits for a login: no user is logged in and the request is not
    /// marked as usable without one.
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


/// Holds the requests that wait for a login. It opens when a user logs in and closes when the session ends.
internal final class ImpulseLoginGate: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var isOpen: Bool
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]


    internal init(isOpen: Bool) {
        self.isOpen = isOpen
    }


    internal func setOpen(_ value: Bool) {
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
    private let onAuthorizationRequired: @Sendable () -> Void
    private static let notInitializedText: String = "CONNECTION_NOT_INITED"


    /// What a token refresh ended with: a fresh session, a refresh that did not renew the session, or a refresh that
    /// failed on the network.
    private enum RefreshStep {
        case refreshed
        case notRefreshed
        case faulted
    }


    /// Creates the service. `signedIn` is the login state at creation; `onAuthorizationRequired` runs when a request
    /// of a signed-in connection ends with a 401 other than `SESSION_PASSWORD_NEEDED`.
    public init(
        session: any ImpulseRequestSession,
        updateCarrier: any ImpulseRequestCarrier,
        mediaCarrier: any ImpulseRequestCarrier,
        poolCarrier: any ImpulseRequestCarrier,
        declarations: (any ImpulseDeclarationGate)?,
        signedIn: Bool,
        onAuthorizationRequired: @escaping @Sendable () -> Void
    ) {
        self.session = session
        self.updateCarrier = updateCarrier
        self.mediaCarrier = mediaCarrier
        self.poolCarrier = poolCarrier
        self.declarations = declarations
        self.loginGate = ImpulseLoginGate(isOpen: signedIn)
        self.onAuthorizationRequired = onAuthorizationRequired
    }


    /// Reports a login or a session end. A login releases the requests that wait for one.
    public func setSignedIn(_ signedIn: Bool) {
        self.loginGate.setOpen(signedIn)
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
        var signedIn: Bool = await self.session.hasSession()
        if ImpulseRequestPolicy.mustWaitForLogin(options: options, loggedIn: signedIn) {
            let released: Bool = await self.loginGate.wait()
            if !released {
                return .failure(.canceled)
            }
            signedIn = await self.session.hasSession()
        }

        let route: ImpulseCarrierRoute = ImpulseCarrier.route(method: request.method, signedIn: signedIn)
        if case .refused(let refusal) = route {
            return .failure(.rpc(refusal))
        }
        if Task.isCancelled {
            return .failure(.canceled)
        }

        var refreshDue: Bool = true
        var declarationAwaited: Bool = false
        var refreshAttempted: Bool = false
        var redeclared: Bool = false
        var failureCount: Int = 0
        var networkAttempt: Int = 1
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
                            let resumed: Bool = await self.pause(
                                seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: networkAttempt)
                            )
                            networkAttempt += 1
                            if !resumed {
                                return .failure(.canceled)
                            }
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

            let settled: Result<[UInt8], ImpulseCarrierFailure> = await self.sendOnce(
                request: request,
                route: route
            )
            switch settled {
            case .success(let reply):
                return .success(reply)

            case .failure(let failure):
                if ImpulseErrors.isCancelled(failure) {
                    return .failure(.canceled)
                }
                guard let error: ImpulseRpcError = ImpulseCarrier.rpcError(from: failure, route: route) else {
                    let resumed: Bool = await self.pause(
                        seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: networkAttempt)
                    )
                    networkAttempt += 1
                    if !resumed {
                        return .failure(.canceled)
                    }
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
                        let resumed: Bool = await self.pause(
                            seconds: ImpulseRequestPolicy.networkFailureSeconds(attempt: networkAttempt)
                        )
                        networkAttempt += 1
                        if !resumed {
                            return .failure(.canceled)
                        }
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
                    let resumed: Bool = await self.pause(seconds: seconds)
                    if !resumed {
                        return .failure(.canceled)
                    }
                }
            }
        }
    }


    private func sendOnce(
        request: ImpulseEncodedRequest,
        route: ImpulseCarrierRoute
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
            timeoutSeconds: ImpulseRequestTimeouts.callSeconds(route: route)
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


    /// Waits for `seconds`. False when the task was cancelled during the wait.
    private func pause(seconds: TimeInterval) async -> Bool {
        if seconds > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return false
            }
        }

        return !Task.isCancelled
    }
}
