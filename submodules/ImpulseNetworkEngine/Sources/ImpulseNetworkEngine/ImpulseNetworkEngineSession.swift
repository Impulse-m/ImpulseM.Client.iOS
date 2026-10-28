import Foundation
import ImpulseTransport
import MtProtoKit
import SwiftSignalKit
import TelegramCore


/// How long the session waits before it sends a request again on its own: after a server error, and after a reply
/// that did not parse. A flood wait waits the time the server asked for.
struct ImpulseNetworkRetryTiming: Equatable {
    /// Seconds before a request that failed with a server error is sent again.
    var serverErrorDelay: Double
    /// Seconds before a request whose reply did not parse is sent again.
    var parseFailureDelay: Double


    static let canonical: ImpulseNetworkRetryTiming = ImpulseNetworkRetryTiming(serverErrorDelay: 2.0, parseFailureDelay: 2.0)


    init(serverErrorDelay: Double, parseFailureDelay: Double) {
        self.serverErrorDelay = serverErrorDelay
        self.parseFailureDelay = parseFailureDelay
    }
}


/// The connection controls of the transport under a session. The engine that owns the transport supplies them: pausing
/// drops the connection and resuming reconnects, and the online state chooses the keepalive timing.
protocol ImpulseNetworkTransportControl: AnyObject {
    func setPaused(_ paused: Bool)
    func setOnline(_ online: Bool)
}


/// One session of the ImpulseM engine: TelegramCore's session interface over one transport session. It takes the
/// requests as TL bytes, sends them through the transport and completes each one as the NetworkEngineSession protocol asks: with the
/// parsed result or the error. Flood waits and server errors are offered to the request's `shouldContinueAfterError`;
/// a reply that does not parse is sent again a bounded number of times. Its state is read and written only on its
/// queue, and the requests complete on that queue too.
final class ImpulseNetworkEngineSession: NetworkEngineSession {
    /// The most sends of a request whose reply does not parse, the first one included.
    private static let parseFailureAttempts: Int = 3
    /// The options of every request on the transport. The session answers server errors and flood waits itself, and
    /// it does not hold a request for a login, as the other engines do not.
    private static let requestOptions: ImpulseRequestOptions = ImpulseRequestOptions(
        withoutLogin: true,
        failOnServerErrors: true,
        failOnServerErrorsExceptFloodWait: false,
        doNotWaitFloodWait: true,
        totalDeadlineSeconds: nil,
        forceDownload: false
    )

    let datacenterId: Int
    let requestService: NetworkEngineRequestService
    /// The transport session the requests go through.
    let transport: ImpulseNetworkSession

    private let role: NetworkEngineSessionRole
    private let queue: DispatchQueue
    private let events: ImpulseNetworkSessionEvents
    private let updateBridge: ImpulseUpdateBridge
    private let timing: ImpulseNetworkRetryTiming
    private let control: ImpulseNetworkTransportControl?
    private let onParseFailure: () -> Void
    private let stopped: Atomic<Bool> = Atomic<Bool>(value: false)
    private weak var delegate: NetworkEngineSessionDelegate?
    private var pending: [ImpulseNetworkPendingRequest] = []
    private var dropObservers: [(NetworkEngineConnectionDrop) -> Void] = []
    private var drainTarget: NetworkEngineRequestService?
    private var drainCompletions: [() -> Void] = []
    private var drainDeadlinePassed: Bool = false
    private var lastHeardAt: Double?
    private var busySince: Double?
    private var connectionDropped: Bool = false
    private var paused: Bool = true
    private var online: Bool = false


    /// Creates the session over the transport that `makeTransport` builds from the events it must report to. Updates go to
    /// `updateBridge` for the main session only. `onParseFailure` runs on every reply that does not parse, so the owner can
    /// clear the initialization state of the context.
    init(
        datacenterId: Int,
        role: NetworkEngineSessionRole,
        delegate: NetworkEngineSessionDelegate?,
        updateBridge: ImpulseUpdateBridge,
        timing: ImpulseNetworkRetryTiming,
        control: ImpulseNetworkTransportControl?,
        onParseFailure: @escaping () -> Void,
        makeTransport: (ImpulseNetworkSessionEvents) -> ImpulseNetworkSession
    ) {
        self.datacenterId = datacenterId
        self.role = role
        self.delegate = delegate
        self.updateBridge = updateBridge
        self.timing = timing
        self.control = control
        self.onParseFailure = onParseFailure
        self.queue = DispatchQueue(label: "org.impulsem.network-engine.session.\(datacenterId)")
        let events: ImpulseNetworkSessionEvents = ImpulseNetworkSessionEvents()
        let transport: ImpulseNetworkSession = makeTransport(events)
        let service: ImpulseNetworkEngineRequestService = ImpulseNetworkEngineRequestService()
        self.events = events
        self.transport = transport
        self.requestService = service
        events.owner = self
        service.session = self
        transport.addUpdateSink(events)
    }


    deinit {
        self.transport.stop()
    }


    func setPaused(_ paused: Bool) {
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            if self.stopped.with({ $0 }) || self.paused == paused {
                return
            }
            self.paused = paused
            self.control?.setPaused(paused)
        }
    }


    func setOnline(_ online: Bool) {
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            if self.stopped.with({ $0 }) || self.online == online {
                return
            }
            self.online = online
            self.control?.setOnline(online)
        }
    }


    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
        self.updateBridge.addSink(sink)
    }


    func stop() {
        if self.stopped.swap(true) {
            return
        }
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            let entries: [ImpulseNetworkPendingRequest] = self.pending
            self.pending.removeAll()
            for entry: ImpulseNetworkPendingRequest in entries {
                entry.cancelled = true
                entry.retryGeneration += 1
                entry.call?.cancel()
                entry.call = nil
            }
            self.transport.stop()
            self.runDrainCompletions()
        }
    }


    /// Moves every request that has not completed to `service`. A request the server may have run stays until its answer
    /// comes, or until `deadline` seconds have passed, after which the policy of the request decides (`networkEngineReleaseDecision`).
    /// `completion` runs once nothing is left here, and the session is then stopped.
    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        self.queue.async { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            if self.stopped.with({ $0 }) {
                completion()
                return
            }
            self.drainCompletions.append(completion)
            if self.drainTarget != nil {
                return
            }
            self.drainTarget = service
            let snapshot: [ImpulseNetworkPendingRequest] = self.pending
            for entry: ImpulseNetworkPendingRequest in snapshot where !entry.mayHaveRun {
                self.moveOut(entry, after: self.remainingWait(of: entry))
            }
            if self.pending.contains(where: { (entry: ImpulseNetworkPendingRequest) -> Bool in
                return entry.mayHaveRun
            }) {
                self.queue.asyncAfter(deadline: .now() + max(0.0, deadline)) { [weak self] in
                    self?.drainDeadlineReached()
                }
            }
            self.checkDrainFinished()
        }
    }


    func observeConnectionDrops(_ observer: @escaping (NetworkEngineConnectionDrop) -> Void) {
        self.queue.async { [weak self] in
            self?.dropObservers.append(observer)
        }
    }


    /// Reports a connection the transport gave up on. The owner of the transport calls it; the observers get it in order.
    func reportConnectionDrop(_ drop: NetworkEngineConnectionDrop) {
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.connectionDropped = true
            for observer in self.dropObservers {
                observer(drop)
            }
        }
    }


    /// What the session heard lately. Nil while it has heard nothing, or while it hands its requests over.
    func serverActivity(_ reply: @escaping (NetworkEngineServerActivity?) -> Void) {
        self.queue.async { [weak self] in
            guard let self = self else {
                reply(nil)
                return
            }
            if self.stopped.with({ $0 }) || self.drainTarget != nil {
                reply(nil)
                return
            }
            let now: Double = ProcessInfo.processInfo.systemUptime
            let silentFor: Double? = self.lastHeardAt.map({ (heard: Double) -> Double in
                return max(0.0, now - heard)
            })
            let waitingFor: Double? = self.busySince.map({ (since: Double) -> Double in
                return max(0.0, now - since)
            })
            let connected: Bool = self.lastHeardAt != nil && !self.connectionDropped
            reply(NetworkEngineServerActivity(silentFor: silentFor, waitingFor: waitingFor, connected: connected))
        }
    }


    /// Takes a request from the request service. The returned disposable cancels it from any thread.
    func add(_ request: NetworkEngineRequest) -> Disposable {
        if self.stopped.with({ $0 }) {
            return EmptyDisposable
        }
        let entry: ImpulseNetworkPendingRequest = ImpulseNetworkPendingRequest(request: request)
        let queue: DispatchQueue = self.queue
        queue.async { [weak self] in
            self?.submit(entry)
        }
        return ActionDisposable {
            queue.async { [weak self] in
                self?.cancel(entry)
            }
        }
    }


    func handleAuthorizationRequired() {
        self.queue.async { [weak self] in
            guard let self = self else {
                return
            }
            if self.role == .main {
                self.delegate?.networkSessionAuthorizationRequired()
            }
        }
    }


    func handleReset() {
        if self.role == .main {
            self.updateBridge.networkSessionDidReset()
        }
    }


    func handleUpdate(tl: [UInt8]) {
        self.queue.async { [weak self] in
            self?.noteHeard()
        }
        if self.role == .main {
            self.updateBridge.networkSessionDidReceive(tl: tl)
        }
    }


    private func submit(_ entry: ImpulseNetworkPendingRequest) {
        if self.stopped.with({ $0 }) || entry.cancelled {
            return
        }
        if self.drainTarget != nil {
            self.moveOut(entry, after: 0.0)
            self.checkDrainFinished()
            return
        }
        if self.pending.isEmpty {
            self.busySince = ProcessInfo.processInfo.systemUptime
        }
        let predecessor: ImpulseNetworkPendingRequest? = self.predecessor(for: entry)
        self.pending.append(entry)
        if let predecessor: ImpulseNetworkPendingRequest = predecessor {
            predecessor.dependents.append(entry)
            return
        }
        self.start(entry)
    }


    /// The latest unsettled request this one must wait for, when its `dependsOn` accepts it.
    private func predecessor(for entry: ImpulseNetworkPendingRequest) -> ImpulseNetworkPendingRequest? {
        guard let accepts: (WrappedRequestMetadata) -> Bool = entry.request.dependsOn else {
            return nil
        }
        return self.pending.last(where: { (candidate: ImpulseNetworkPendingRequest) -> Bool in
            return !candidate.finished && accepts(candidate.request.metadata)
        })
    }


    /// Sends the request now, unless it is settled, cancelled or moved, or the session is stopped. While the session hands
    /// its requests over, a request that may have run waits for its deadline, and one that has not run moves at once.
    private func start(_ entry: ImpulseNetworkPendingRequest) {
        if entry.finished || entry.cancelled || entry.moved != nil || entry.call != nil {
            return
        }
        if self.stopped.with({ $0 }) {
            return
        }
        if self.drainTarget != nil {
            if !entry.mayHaveRun {
                self.moveOut(entry, after: 0.0)
            } else if self.drainDeadlinePassed {
                self.releaseSentEntry(entry)
            }
            self.checkDrainFinished()
            return
        }
        self.dispatch(entry)
    }


    private func dispatch(_ entry: ImpulseNetworkPendingRequest) {
        entry.attempt += 1
        let attempt: Int = entry.attempt
        entry.attemptStartedAt = ProcessInfo.processInfo.systemUptime
        let request: NetworkEngineRequest = entry.request
        let parse: (Data) -> Any? = request.parse
        let queue: DispatchQueue = self.queue
        let impulseRequest: ImpulseNetworkRequest = ImpulseNetworkRequest(
            tl: [UInt8](request.payload),
            options: ImpulseNetworkEngineSession.requestOptions,
            dependsOn: nil,
            acknowledged: { [weak self, weak entry] in
                queue.async {
                    self?.acknowledge(entry: entry, attempt: attempt)
                }
            },
            parse: { (bytes: [UInt8]) -> Any? in
                return parse(Data(bytes))
            },
            completed: { [weak self, weak entry] (result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void in
                queue.async {
                    self?.settle(entry: entry, attempt: attempt, result: result)
                }
            }
        )
        // The carrier may send the call before its acknowledgement reaches this queue, so from here on the call may have run.
        entry.mayHaveRun = true
        guard let call: ImpulseRequestCall = self.transport.add(impulseRequest) else {
            self.remove(entry)
            return
        }
        entry.call = call
    }


    private func acknowledge(entry: ImpulseNetworkPendingRequest?, attempt: Int) {
        guard let entry: ImpulseNetworkPendingRequest = entry else {
            return
        }
        if entry.attempt != attempt || entry.finished || entry.cancelled {
            return
        }
        entry.mayHaveRun = true
        if entry.acknowledgedReported {
            return
        }
        entry.acknowledgedReported = true
        entry.request.acknowledged?()
    }


    private func settle(entry: ImpulseNetworkPendingRequest?, attempt: Int, result: Result<ImpulseNetworkResponse, ImpulseRequestFailure>) {
        guard let entry: ImpulseNetworkPendingRequest = entry else {
            return
        }
        if entry.attempt != attempt || entry.finished || entry.cancelled {
            return
        }
        entry.call = nil
        switch result {
        case .success(let response):
            self.noteHeard()
            self.finish(entry, outcome: .success(NetworkEngineResponse(result: response.result, info: self.responseInfo(entry))))

        case .failure(.rpc(let error)):
            self.noteHeard()
            self.handleRpcFailure(entry, error: error)

        case .failure(.network):
            self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: ImpulseNetworkEngineFailures.networkFailure, info: self.responseInfo(entry))))

        case .failure(.canceled):
            return
        }
    }


    private func handleRpcFailure(_ entry: ImpulseNetworkPendingRequest, error: ImpulseRpcError) {
        if ImpulseNetworkEngineFailures.isParsingFailure(error) {
            self.handleParseFailure(entry)
            return
        }
        if ImpulseNetworkEngineFailures.isNotAcceptable(error) && self.role == .main {
            self.delegate?.networkSessionSoftAuthReset()
        }
        if ImpulseNetworkEngineFailures.isAnswerLost(error) {
            self.retire(entry)
            return
        }
        if ImpulseNetworkEngineFailures.isFlood(error) {
            self.handleFloodWait(entry, error: error)
            return
        }
        if ImpulseNetworkEngineFailures.isServerError(error) {
            self.handleServerError(entry, error: error)
            return
        }
        self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: ImpulseNetworkEngineFailures.rpcError(error), info: self.responseInfo(entry))))
    }


    private func handleFloodWait(_ entry: ImpulseNetworkPendingRequest, error: ImpulseRpcError) {
        let seconds: Int = ImpulseErrors.floodWaitSeconds(error) ?? Int(ImpulseRequestPolicy.defaultFloodWaitSeconds)
        let context: NetworkEngineErrorContext = entry.errorState.applyFlood(seconds: seconds, text: error.text)
        if !entry.request.shouldContinueAfterError(context) {
            self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: ImpulseNetworkEngineFailures.rpcError(error), info: self.responseInfo(entry))))
            return
        }
        // The server answered the flood wait without running the call, so a hand-over may move it at once.
        entry.mayHaveRun = false
        self.scheduleRetry(entry, after: TimeInterval(seconds))
    }


    private func handleServerError(_ entry: ImpulseNetworkPendingRequest, error: ImpulseRpcError) {
        let context: NetworkEngineErrorContext = entry.errorState.applyServerError()
        if !entry.request.shouldContinueAfterError(context) {
            self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: ImpulseNetworkEngineFailures.rpcError(error), info: self.responseInfo(entry))))
            return
        }
        entry.errorState.didResubmit()
        self.scheduleRetry(entry, after: self.timing.serverErrorDelay)
    }


    private func handleParseFailure(_ entry: ImpulseNetworkPendingRequest) {
        self.onParseFailure()
        let context: NetworkEngineErrorContext = entry.errorState.applyParseFailure()
        let attemptsLeft: Bool = entry.errorState.parseFailures < ImpulseNetworkEngineSession.parseFailureAttempts
        if attemptsLeft && entry.request.shouldContinueAfterError(context) {
            entry.errorState.didResubmit()
            self.scheduleRetry(entry, after: self.timing.parseFailureDelay)
            return
        }
        self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: ImpulseNetworkEngineFailures.parsingFailure(), info: self.responseInfo(entry))))
    }


    private func scheduleRetry(_ entry: ImpulseNetworkPendingRequest, after delaySeconds: Double) {
        entry.retryGeneration += 1
        let generation: Int = entry.retryGeneration
        let delay: Double = max(0.0, delaySeconds)
        entry.retryDueAt = ProcessInfo.processInfo.systemUptime + delay
        self.queue.asyncAfter(deadline: .now() + delay) { [weak self, weak entry] in
            guard let self = self, let entry: ImpulseNetworkPendingRequest = entry else {
                return
            }
            if entry.retryGeneration != generation {
                return
            }
            entry.retryDueAt = nil
            self.start(entry)
        }
    }


    /// Settles a request that the hand-over found sent, once its deadline has passed: it moves when its policy allows a
    /// server error, and fails with `ENGINE_SWITCHED` otherwise.
    private func releaseSentEntry(_ entry: ImpulseNetworkPendingRequest) {
        let decision: NetworkEngineReleaseDecision = networkEngineReleaseDecision(mayHaveRun: true, retryAfter: 0.0, allowsServerError: { () -> Bool in
            return entry.request.shouldContinueAfterError(entry.errorState.applyServerError())
        })
        switch decision {
        case .move(let after):
            self.moveOut(entry, after: after)

        case .fail:
            self.finish(entry, outcome: .failure(NetworkEngineRequestFailure(error: networkEngineSwitchedError, info: self.responseInfo(entry))))
        }
    }


    private func drainDeadlineReached() {
        if self.drainTarget == nil || self.stopped.with({ $0 }) {
            return
        }
        self.drainDeadlinePassed = true
        let snapshot: [ImpulseNetworkPendingRequest] = self.pending
        for entry: ImpulseNetworkPendingRequest in snapshot where entry.mayHaveRun && !entry.finished && entry.moved == nil {
            self.releaseSentEntry(entry)
        }
        self.checkDrainFinished()
    }


    /// Hands a request to the hand-over target. Its call here is cancelled, and it is added to the target after `delay`.
    private func moveOut(_ entry: ImpulseNetworkPendingRequest, after delay: Double) {
        guard let target: NetworkEngineRequestService = self.drainTarget else {
            return
        }
        if entry.moved != nil || entry.finished || entry.cancelled {
            return
        }
        entry.retryGeneration += 1
        entry.retryDueAt = nil
        let call: ImpulseRequestCall? = entry.call
        entry.call = nil
        call?.cancel()
        self.remove(entry)
        self.releaseDependents(of: entry)
        entry.moved = networkEngineMove(entry.request, to: target, after: delay)
    }


    private func remainingWait(of entry: ImpulseNetworkPendingRequest) -> Double {
        guard let due: Double = entry.retryDueAt else {
            return 0.0
        }
        return max(0.0, due - ProcessInfo.processInfo.systemUptime)
    }


    /// Completes the hand-over once nothing is left, and stops the session.
    private func checkDrainFinished() {
        if self.drainTarget == nil || !self.pending.isEmpty {
            return
        }
        let _: Bool = self.stopped.swap(true)
        self.transport.stop()
        self.runDrainCompletions()
    }


    private func runDrainCompletions() {
        let completions: [() -> Void] = self.drainCompletions
        self.drainCompletions.removeAll()
        for completion in completions {
            completion()
        }
    }


    private func cancel(_ entry: ImpulseNetworkPendingRequest) {
        if entry.finished || entry.cancelled {
            return
        }
        entry.cancelled = true
        entry.retryGeneration += 1
        entry.retryDueAt = nil
        let call: ImpulseRequestCall? = entry.call
        entry.call = nil
        call?.cancel()
        let moved: Disposable? = entry.moved
        entry.moved = nil
        moved?.dispose()
        self.remove(entry)
        self.releaseDependents(of: entry)
        self.checkDrainFinished()
    }


    /// Completes a request with `outcome` and forgets it. The requests that waited for it are sent now.
    private func finish(_ entry: ImpulseNetworkPendingRequest, outcome: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) {
        if entry.finished || entry.cancelled {
            return
        }
        self.detach(entry)
        entry.request.completed(outcome)
        self.checkDrainFinished()
    }


    /// Forgets a request without completing it.
    private func retire(_ entry: ImpulseNetworkPendingRequest) {
        if entry.finished {
            return
        }
        self.detach(entry)
        self.checkDrainFinished()
    }


    private func detach(_ entry: ImpulseNetworkPendingRequest) {
        entry.finished = true
        entry.retryGeneration += 1
        entry.retryDueAt = nil
        let call: ImpulseRequestCall? = entry.call
        entry.call = nil
        call?.cancel()
        self.remove(entry)
        self.releaseDependents(of: entry)
    }


    private func releaseDependents(of entry: ImpulseNetworkPendingRequest) {
        let dependents: [ImpulseNetworkPendingRequest] = entry.dependents
        entry.dependents.removeAll()
        for dependent: ImpulseNetworkPendingRequest in dependents {
            self.start(dependent)
        }
    }


    private func remove(_ entry: ImpulseNetworkPendingRequest) {
        self.pending.removeAll(where: { (candidate: ImpulseNetworkPendingRequest) -> Bool in
            return candidate === entry
        })
        if self.pending.isEmpty {
            self.busySince = nil
        }
    }


    private func noteHeard() {
        self.lastHeardAt = ProcessInfo.processInfo.systemUptime
        self.connectionDropped = false
    }


    private func responseInfo(_ entry: ImpulseNetworkPendingRequest) -> NetworkEngineResponseInfo {
        let duration: Double = max(0.0, ProcessInfo.processInfo.systemUptime - entry.attemptStartedAt)
        return NetworkEngineResponseInfo(timestamp: Date().timeIntervalSince1970, networkType: 0, duration: duration)
    }
}
