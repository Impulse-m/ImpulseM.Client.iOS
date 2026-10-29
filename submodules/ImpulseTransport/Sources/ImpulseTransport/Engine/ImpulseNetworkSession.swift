import Foundation


/// The role of a session. The main session is the account's session to its master datacenter; a worker session serves
/// transfers.
public enum ImpulseSessionRole: Equatable, Sendable {
    /// The account's session to its master datacenter. A signed-in `401` on it is an authorization failure.
    case main
    /// A download or upload session. `masterDatacenterId` is the datacenter the account lives on.
    case worker(masterDatacenterId: Int, isMedia: Bool, isCdn: Bool)
}


/// Events of the main session.
public protocol ImpulseNetworkSessionDelegate: AnyObject {
    /// A signed-in main session got a `401` other than `SESSION_PASSWORD_NEEDED`: the account must sign in again.
    func networkSessionAuthorizationRequired()
}


/// Receiver of the non-RPC messages of a session, in receive order.
public protocol ImpulseUpdateSink: AnyObject {
    /// The session was reset: updates may have been lost, so the receiver must resynchronize.
    func networkSessionDidReset()

    /// A realtime update as its TL bytes, with the name of the realtime lane it came on, such as `system:config`.
    func networkSessionDidReceive(tl: [UInt8], channel: String)
}


/// One RPC call as a session takes it: the TL bytes of the call, its options and its hooks.
public struct ImpulseNetworkRequest {
    /// The TL-serialized API function. The transport adds the wrappers it needs.
    public let tl: [UInt8]
    /// The retry and delivery options of the call.
    public let options: ImpulseRequestOptions
    /// When set, the call is sent after the latest earlier call whose method this closure accepts has settled.
    public let dependsOn: ((String) -> Bool)?
    /// When set, called once when the call is handed to its carrier.
    public let acknowledged: (() -> Void)?
    /// Parses the TL reply. A nil result completes the call with `500 TL_PARSING_ERROR`.
    public let parse: ([UInt8]) -> Any?
    /// Called exactly once, unless the call is cancelled first.
    public let completed: (Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void


    public init(
        tl: [UInt8],
        options: ImpulseRequestOptions = ImpulseRequestOptions(),
        dependsOn: ((String) -> Bool)? = nil,
        acknowledged: (() -> Void)? = nil,
        parse: @escaping ([UInt8]) -> Any?,
        completed: @escaping (Result<ImpulseNetworkResponse, ImpulseRequestFailure>) -> Void
    ) {
        self.tl = tl
        self.options = options
        self.dependsOn = dependsOn
        self.acknowledged = acknowledged
        self.parse = parse
        self.completed = completed
    }
}


/// A successful reply. `result` is what `ImpulseNetworkRequest.parse` returned for the reply.
public struct ImpulseNetworkResponse {
    public let result: Any


    public init(result: Any) {
        self.result = result
    }
}


/// One session of the ImpulseM transport to one datacenter. It submits requests to the request service of its connection,
/// completes each one as the engine expects (parsed result, or the error), and hands the update sink the messages it
/// receives. Any datacenter id is valid. The session is safe to use from any thread.
public final class ImpulseNetworkSession: @unchecked Sendable {
    /// The error of a reply that the parser refused.
    public static let tlParsingError: ImpulseRpcError = ImpulseRpcError(code: 500, text: "TL_PARSING_ERROR", temporary: false)
    /// The error of a call whose reply the transcoder could not convert, when the transcoder gives none.
    public static let responseParseError: ImpulseRpcError = ImpulseRpcError(code: 400, text: "CLIENT_RESPONSE_PARSE_FAILED", temporary: false)
    /// The error of a call that the transcoder could not encode, when the transcoder gives none.
    public static let encodeError: ImpulseRpcError = ImpulseRpcError(code: 400, text: "CLIENT_TRANSCODE_FAILED", temporary: false)
    /// The error of a login reply whose tokens come without a usable authorization, as Android answers it.
    private static let loginReplyError: ImpulseRpcError = ImpulseRpcError(code: 400, text: "TRANSCODE_FAILED", temporary: false)
    private static let sessionTokenField: String = "session_token"
    private static let refreshTokenField: String = "refresh_token"

    public let datacenterId: Int
    public let role: ImpulseSessionRole

    private let transcoder: ImpulseTranscoder
    private let service: ImpulseRequestService
    private let sessionInstaller: ImpulseSessionInstaller?
    private weak var delegate: (any ImpulseNetworkSessionDelegate)?
    private let lock: NSLock = NSLock()
    private var isStopped: Bool = false
    private var sinks: [any ImpulseUpdateSink] = []
    private var activeCalls: [ImpulseActiveCall] = []


    /// Creates a session. `signedIn` is the login state at creation. The carriers are wrapped so that a call is
    /// acknowledged when its first send reaches a carrier.
    public init(
        datacenterId: Int,
        role: ImpulseSessionRole,
        transcoder: ImpulseTranscoder,
        session: any ImpulseRequestSession,
        updateCarrier: any ImpulseRequestCarrier,
        mediaCarrier: any ImpulseRequestCarrier,
        poolCarrier: any ImpulseRequestCarrier,
        declarations: (any ImpulseDeclarationGate)?,
        signedIn: Bool,
        delegate: (any ImpulseNetworkSessionDelegate)?,
        clock: any ImpulseRequestClock = ImpulseSystemRequestClock(),
        loginGate: ImpulseLoginGate? = nil,
        identityTag: (@Sendable () async -> String?)? = nil,
        sessionInstaller: ImpulseSessionInstaller? = nil
    ) {
        self.datacenterId = datacenterId
        self.role = role
        self.transcoder = transcoder
        self.sessionInstaller = sessionInstaller
        self.delegate = delegate

        let isMain: Bool = role == .main
        let authorizationRequired: @Sendable () -> Void = { [weak delegate] in
            if !isMain {
                return
            }
            delegate?.networkSessionAuthorizationRequired()
        }

        self.service = ImpulseRequestService(
            session: session,
            updateCarrier: ImpulseSendReportingCarrier(inner: updateCarrier),
            mediaCarrier: ImpulseSendReportingCarrier(inner: mediaCarrier),
            poolCarrier: ImpulseSendReportingCarrier(inner: poolCarrier),
            declarations: declarations,
            signedIn: signedIn,
            onAuthorizationRequired: authorizationRequired,
            clock: clock,
            loginGate: loginGate,
            identityTag: identityTag
        )
    }


    /// Submits a call. Returns the call that carries it, or nil when the session is stopped: a refused call never
    /// completes.
    public func add(_ request: ImpulseNetworkRequest) -> ImpulseRequestCall? {
        if self.isStoppedNow() {
            return nil
        }

        let encoded: ImpulseEncodedRequest
        do {
            encoded = try self.transcoder.encodeRequest(tl: request.tl)
        } catch {
            let failure: ImpulseRpcError = (error as? ImpulseTranscodeError)?.rpcError ?? ImpulseNetworkSession.encodeError
            let refused: Task<Result<[UInt8], ImpulseRequestFailure>, Never> = Task {
                return .failure(.rpc(failure))
            }
            let refusedCall: ImpulseRequestCall = ImpulseRequestCall(result: refused)
            self.deliver(request: request, method: "", methodId: 0, identifier: UUID(), call: refusedCall)
            return refusedCall
        }

        let predecessor: ImpulseRequestCall? = self.predecessor(accepting: request.dependsOn)
        let report: ImpulseSendReport = ImpulseSendReport(onSent: request.acknowledged)
        let options: ImpulseRequestOptions = ImpulseNetworkSession.loginOptions(request.options, method: encoded.method)
        let inner: ImpulseRequestCall = ImpulseSendReportContext.$current.withValue(report) {
            return self.service.submit(
                request: encoded,
                options: options,
                dependsOn: predecessor
            )
        }

        let outer: ImpulseRequestCall = ImpulseNetworkSession.wrap(inner: inner)
        let identifier: UUID = UUID()

        self.lock.lock()
        if self.isStopped {
            self.lock.unlock()
            outer.cancel()
            return nil
        }
        self.activeCalls.append(ImpulseActiveCall(identifier: identifier, method: encoded.method, call: outer))
        self.lock.unlock()

        self.deliver(
            request: request,
            method: encoded.method,
            methodId: encoded.methodId,
            identifier: identifier,
            call: outer
        )
        return outer
    }


    /// The options of a call with its login flag set per method, as Android does: a call of an identity-socket method is
    /// sent without a login, and every other call waits for one. A caller may still ask for `withoutLogin` itself.
    private static func loginOptions(
        _ options: ImpulseRequestOptions,
        method: String
    ) -> ImpulseRequestOptions {
        let identitySocketMethod: Bool = ImpulseMethodClasses.identitySocketMethods.contains(method)
        return ImpulseRequestOptions(
            withoutLogin: options.withoutLogin || identitySocketMethod,
            failOnServerErrors: options.failOnServerErrors,
            failOnServerErrorsExceptFloodWait: options.failOnServerErrorsExceptFloodWait,
            doNotWaitFloodWait: options.doNotWaitFloodWait,
            totalDeadlineSeconds: options.totalDeadlineSeconds,
            forceDownload: options.forceDownload
        )
    }


    /// Reports a login or a session end to the request service. A login releases the calls that wait for one.
    public func setSignedIn(_ signedIn: Bool) {
        self.service.setSignedIn(signedIn)
    }


    /// Tears the session down: its calls are cancelled, they complete no more, and `add` refuses from now on.
    public func stop() {
        self.lock.lock()
        if self.isStopped {
            self.lock.unlock()
            return
        }
        self.isStopped = true
        let calls: [ImpulseActiveCall] = self.activeCalls
        self.activeCalls.removeAll()
        self.sinks.removeAll()
        self.lock.unlock()

        for entry: ImpulseActiveCall in calls {
            entry.call.cancel()
        }
    }


    public func addUpdateSink(_ sink: any ImpulseUpdateSink) {
        self.lock.lock()
        self.sinks.append(sink)
        self.lock.unlock()
    }


    /// Hands the sinks a reset of the session.
    public func deliverReset() {
        for sink: any ImpulseUpdateSink in self.currentSinks() {
            sink.networkSessionDidReset()
        }
    }


    /// Hands the sinks one received update, as its TL bytes, with the name of the realtime lane it came on.
    public func deliverUpdate(tl: [UInt8], channel: String) {
        for sink: any ImpulseUpdateSink in self.currentSinks() {
            sink.networkSessionDidReceive(tl: tl, channel: channel)
        }
    }


    private func isStoppedNow() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.isStopped
    }


    private func currentSinks() -> [any ImpulseUpdateSink] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.isStopped {
            return []
        }
        return self.sinks
    }


    /// The latest active call whose method the closure accepts: the predecessor of a call that depends on it.
    private func predecessor(accepting dependsOn: ((String) -> Bool)?) -> ImpulseRequestCall? {
        guard let accepts: (String) -> Bool = dependsOn else {
            return nil
        }

        self.lock.lock()
        let snapshot: [ImpulseActiveCall] = self.activeCalls
        self.lock.unlock()

        for entry: ImpulseActiveCall in snapshot.reversed() {
            if accepts(entry.method) {
                return entry.call
            }
        }
        return nil
    }


    /// Makes the call settle only as the session sees it: a cancelled call settles as canceled even when the reply
    /// arrived after the cancellation, and cancelling it cancels the call of the request service.
    private static func wrap(inner: ImpulseRequestCall) -> ImpulseRequestCall {
        let task: Task<Result<[UInt8], ImpulseRequestFailure>, Never> = Task {
            let value: Result<[UInt8], ImpulseRequestFailure> = await withTaskCancellationHandler(
                operation: {
                    return await inner.result.value
                },
                onCancel: {
                    inner.cancel()
                }
            )
            if Task.isCancelled {
                return .failure(.canceled)
            }
            return value
        }
        return ImpulseRequestCall(result: task)
    }


    /// Completes the request once its call settles, and forgets the call.
    private func deliver(
        request: ImpulseNetworkRequest,
        method: String,
        methodId: UInt32,
        identifier: UUID,
        call: ImpulseRequestCall
    ) {
        Task {
            let result: Result<[UInt8], ImpulseRequestFailure> = await call.result.value
            self.forget(identifier: identifier)
            await self.settle(request: request, method: method, methodId: methodId, result: result)
        }
    }


    private func forget(identifier: UUID) {
        self.lock.lock()
        self.activeCalls.removeAll(where: { (entry: ImpulseActiveCall) -> Bool in
            return entry.identifier == identifier
        })
        self.lock.unlock()
    }


    /// Completes the request once its reply is parsed. A reply that carries session tokens installs the session first, so the
    /// caller never sees the reply before the session and the socket carry the new token.
    private func settle(
        request: ImpulseNetworkRequest,
        method: String,
        methodId: UInt32,
        result: Result<[UInt8], ImpulseRequestFailure>
    ) async {
        switch result {
        case .failure(.canceled):
            return

        case .failure(let failure):
            request.completed(.failure(failure))

        case .success(let reply):
            let parsed: Result<ImpulseNetworkResponse, ImpulseRequestFailure> = await self.parse(
                request: request,
                method: method,
                methodId: methodId,
                reply: reply
            )
            request.completed(parsed)
        }
    }


    private func parse(
        request: ImpulseNetworkRequest,
        method: String,
        methodId: UInt32,
        reply: [UInt8]
    ) async -> Result<ImpulseNetworkResponse, ImpulseRequestFailure> {
        var captured: [String: String] = [:]
        let tl: [UInt8]
        do {
            tl = try self.transcoder.decodeResult(
                methodId: methodId,
                proto: reply,
                capture: { (protoMessage: String, fieldName: String, value: String) -> Void in
                    captured[fieldName] = value
                }
            )
        } catch {
            let rpcError: ImpulseRpcError = (error as? ImpulseTranscodeError)?.rpcError ?? ImpulseNetworkSession.responseParseError
            return .failure(.rpc(rpcError))
        }

        if let installFailure: ImpulseRequestFailure = await self.installSession(method: method, tl: tl, captured: captured) {
            return .failure(installFailure)
        }

        guard let parsed: Any = request.parse(tl) else {
            return .failure(.rpc(ImpulseNetworkSession.tlParsingError))
        }
        return .success(ImpulseNetworkResponse(result: parsed))
    }


    /// Installs the session when the reply carries session tokens, whichever method answered, as Android does. Tokens
    /// that come without a usable authorization, or an install that is refused, fail the call as a transcode error.
    private func installSession(
        method: String,
        tl: [UInt8],
        captured: [String: String]
    ) async -> ImpulseRequestFailure? {
        guard let installer: ImpulseSessionInstaller = self.sessionInstaller else {
            return nil
        }
        guard captured[ImpulseNetworkSession.sessionTokenField] != nil else {
            return nil
        }
        guard captured[ImpulseNetworkSession.refreshTokenField] != nil else {
            return nil
        }

        guard let authorization: [UInt8] = await installer.authorization(inResult: tl) else {
            return ImpulseRequestFailure.rpc(ImpulseNetworkSession.loginReplyError)
        }
        do {
            _ = try await installer.install(method: method, authorization: authorization, captured: captured)
            return nil
        } catch {
            return ImpulseRequestFailure.rpc(ImpulseNetworkSession.loginReplyError)
        }
    }
}


/// A call the session has in flight, with the method it carries for the dependency lookup.
private struct ImpulseActiveCall {
    let identifier: UUID
    let method: String
    let call: ImpulseRequestCall
}


/// Reports the first send of a call to the call that asked for it.
private final class ImpulseSendReport: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var reported: Bool = false
    private let onSent: (() -> Void)?


    init(onSent: (() -> Void)?) {
        self.onSent = onSent
    }


    func markSent() {
        self.lock.lock()
        let first: Bool = !self.reported
        self.reported = true
        self.lock.unlock()

        if first {
            self.onSent?()
        }
    }
}


/// The report of the call whose request service is running on this task. Tasks created while it is bound inherit it.
private enum ImpulseSendReportContext {
    @TaskLocal static var current: ImpulseSendReport? = nil
}


/// A carrier that reports the send of each call to the report bound to its task, and then sends through `inner`.
private struct ImpulseSendReportingCarrier: ImpulseRequestCarrier {
    let inner: any ImpulseRequestCarrier


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        ImpulseSendReportContext.current?.markSent()
        return await self.inner.send(method: method, data: data, timeoutSeconds: timeoutSeconds)
    }
}
