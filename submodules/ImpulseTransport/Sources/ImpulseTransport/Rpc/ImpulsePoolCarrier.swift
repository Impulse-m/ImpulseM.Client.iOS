import Foundation
import SwiftCentrifuge


/// Why a pool call did not succeed. A call of the pool settles with one of these, never with a token.
public enum ImpulsePoolFailure: Error, Equatable {
    /// The main client is disconnected for good, and its session did not end (`clientDisconnected` in the SDK).
    case mainDisconnected
    /// The main client's session ended (`unauthorized` in the SDK). A fresh identity is needed before the pool serves.
    case sessionEnded
    /// A server reply, a local refusal, or an SDK failure that is not a session event.
    case carrier(ImpulseCarrierFailure)
}


/// Handle of one pool call. `cancel()` stops the call; calling it after the call settled does nothing.
public struct ImpulsePoolCall {
    private let onCancel: () -> Void


    internal init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }


    public func cancel() {
        self.onCancel()
    }
}


/// Renews the identity of the app before the main client connects again after its session ended. The completion runs
/// once, on any thread.
public typealias ImpulsePoolIdentityRenewal = (@escaping (Result<Void, Error>) -> Void) -> Void


/// The main client of a pool, as the carrier drives it: its state, its connect and its disconnect. The carrier disconnects
/// it only in `resetMain()`, when the route changes.
internal protocol ImpulsePoolMain: AnyObject {
    var state: CentrifugeClientState { get }

    func connect()

    func disconnect()
}


/// Creates the main client of a pool from its configuration and its delegate.
internal typealias ImpulsePoolMainClientFactory = (
    String,
    CentrifugeClientConfig,
    ImpulsePoolMainDelegate
) throws -> CentrifugeClient


/// The pool the carrier sends calls through. Returns a closure that cancels the call.
internal protocol ImpulsePoolTransport: AnyObject {
    func send(
        endpointKey: String,
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void
}


extension CentrifugeClient: ImpulsePoolMain {
}


extension CentrifugeRpcPool: ImpulsePoolTransport {
    internal func send(
        endpointKey: String,
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        let options: CentrifugeRpcPoolCallOptions = CentrifugeRpcPoolCallOptions(
            headers: [:],
            timeout: timeout,
            affinity: nil
        )
        let call: CentrifugeRpcCall = self.rpc(
            endpointKey: endpointKey,
            method: method,
            data: data,
            options: options
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            switch result {
            case .success(let reply):
                completion(.success(reply.data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        return {
            call.cancel()
        }
    }
}


/// Receives the events of the main client. The SDK calls it on the main client's queue.
internal final class ImpulsePoolMainDelegate: CentrifugeClientDelegate {
    internal var onDisconnect: ((UInt32) -> Void)? = nil


    internal func onDisconnected(
        _ client: CentrifugeClient,
        _ event: CentrifugeDisconnectedEvent
    ) {
        self.onDisconnect?(event.code)
    }
}


/// One SDK rpc pool on one endpoint, served by a dedicated main client that the app connects and disconnects only to
/// move it to a new route.
///
/// The pool never presents a token: its connections carry none, and only the identity methods are served. The
/// watchdog connects the main again when the SDK left it disconnected while the pool is wanted. A main whose session
/// ended renews the identity first. `resetMain()` disconnects the main once after a route change, and the watchdog
/// connects it again over the current route. A pool call fails only while the main is disconnected, with
/// `ImpulsePoolFailure.mainDisconnected` or `.sessionEnded`.
///
/// Completions run on the pool's queue, except local refusals, which run on the carrier's queue. The carrier is thread-safe.
public final class ImpulsePoolCarrier {
    /// The methods the token-less pool serves. Other methods are refused locally without being sent.
    public static let servedMethods: Set<String> = [
        "connectionIdentity",
        "refreshSession",
    ]

    /// The endpoint key the pool resolves. The pool has one endpoint, so the key is fixed.
    public static let endpointKey: String = "impulse-pool"

    /// The name the connections and the main client report to the server when the carrier is not given one. The macOS
    /// app keeps this value; other apps pass their own name to `init`.
    public static let clientName: String = "impulsem-desktop"

    /// The deadline of a pool call, in seconds. A call asks for at most this.
    public static let callTimeoutSeconds: TimeInterval = 30.0

    private static let idleTimeoutSeconds: TimeInterval = 60.0
    private static let maxQueued: Int = 64
    private static let maxConnectionsPerEndpoint: Int = 1
    private static let maxInflightPerConnection: Int = 1
    private static let watchdogIntervalSeconds: TimeInterval = 1.0
    private static let renewalRetrySeconds: TimeInterval = 5.0
    private static let identityRefusedText: String = "CLIENT_IDENTITY_REFUSED"
    private static let localRefusalCode: Int = 400
    /// The disconnect code of an unauthorized end of the session. The SDK keeps the same value internally.
    private static let unauthorizedDisconnectCode: UInt32 = 1

    private let queue: DispatchQueue = DispatchQueue(label: "net.impulsem.transport.pool-carrier")
    private let main: ImpulsePoolMain
    private let transport: ImpulsePoolTransport
    private let identityRenewal: ImpulsePoolIdentityRenewal
    private let clock: () -> UInt64
    private let tickInterval: TimeInterval?
    private let mainDelegate: ImpulsePoolMainDelegate?

    private var wanted: Bool = false
    private var mainResetPending: Bool = false
    private var sessionEnded: Bool = false
    private var renewalInFlight: Bool = false
    private var renewalRetryAtNanos: UInt64 = 0
    private var timer: DispatchSourceTimer? = nil


    /// Creates a carrier with its own main client and pool on the endpoint. The main client is created with
    /// `mainConfig`, or with `makeMainConfig(clientName:)` when none is given. The connections and the main client report
    /// `clientName` to the server.
    /// - Throws: `CentrifugeError.configurationError` when the pool options cannot work.
    public convenience init(
        endpoint: String,
        identityRenewal: @escaping ImpulsePoolIdentityRenewal,
        mainConfig: CentrifugeClientConfig? = nil,
        clientName: String = ImpulsePoolCarrier.clientName
    ) throws {
        try self.init(
            endpoint: endpoint,
            identityRenewal: identityRenewal,
            mainConfig: mainConfig,
            clientName: clientName,
            makeMainClient: ImpulsePoolCarrier.createMainClient
        )
    }


    internal init(
        endpoint: String,
        identityRenewal: @escaping ImpulsePoolIdentityRenewal,
        mainConfig: CentrifugeClientConfig?,
        clientName: String = ImpulsePoolCarrier.clientName,
        makeMainClient: ImpulsePoolMainClientFactory
    ) throws {
        let delegate: ImpulsePoolMainDelegate = ImpulsePoolMainDelegate()
        let config: CentrifugeClientConfig = mainConfig ?? ImpulsePoolCarrier.makeMainConfig(clientName: clientName)
        let main: CentrifugeClient = try makeMainClient(endpoint, config, delegate)
        let pool: CentrifugeRpcPool = try CentrifugeRpcPool.create(
            main: main,
            options: ImpulsePoolCarrier.makePoolOptions(endpoint: endpoint, clientName: clientName)
        )
        self.main = main
        self.transport = pool
        self.identityRenewal = identityRenewal
        self.clock = ImpulsePoolCarrier.nowNanos
        self.tickInterval = ImpulsePoolCarrier.watchdogIntervalSeconds
        self.mainDelegate = delegate
        delegate.onDisconnect = { [weak self] (code: UInt32) -> Void in
            self?.handleMainDisconnected(code: code)
        }
    }


    internal init(
        main: ImpulsePoolMain,
        transport: ImpulsePoolTransport,
        identityRenewal: @escaping ImpulsePoolIdentityRenewal,
        clock: @escaping () -> UInt64,
        tickInterval: TimeInterval?
    ) {
        self.main = main
        self.transport = transport
        self.identityRenewal = identityRenewal
        self.clock = clock
        self.tickInterval = tickInterval
        self.mainDelegate = nil
    }


    deinit {
        self.timer?.cancel()
    }


    /// Connects the main client and starts the watchdog. Calling it again changes nothing once started.
    public func start() {
        self.queue.sync {
            self.wanted = true
            self.runWatchdog()
            self.startTimer()
        }
    }


    /// Stops the watchdog and stops restarting the main. The main is not disconnected by `stop()`.
    public func stop() {
        self.queue.sync {
            self.wanted = false
            self.timer?.cancel()
            self.timer = nil
        }
    }


    /// Disconnects the main once, after a route change, so that the watchdog connects it again over the current route. It
    /// does not change whether the pool is wanted, so a stopped carrier never reconnects. Calls made again before the
    /// watchdog reconnects do nothing.
    public func resetMain() {
        self.queue.sync {
            guard !self.mainResetPending else {
                return
            }
            self.mainResetPending = true
            if self.main.state != .disconnected {
                self.main.disconnect()
            }
        }
    }


    /// Sends a call through the pool. A method outside `servedMethods` is refused locally, and nothing is sent. A
    /// timeout above `callTimeoutSeconds` is cut to it; a timeout of zero or less means `callTimeoutSeconds`.
    public func call(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulsePoolFailure>) -> Void
    ) -> ImpulsePoolCall {
        guard ImpulsePoolCarrier.servedMethods.contains(method) else {
            let failure: ImpulseCarrierFailure = ImpulseCarrierFailure(
                sdkCode: 0,
                appCode: ImpulsePoolCarrier.localRefusalCode,
                appType: ImpulsePoolCarrier.identityRefusedText,
                metadata: [:]
            )
            self.queue.async {
                completion(.failure(.carrier(failure)))
            }
            return ImpulsePoolCall(onCancel: {})
        }
        let timeout: TimeInterval? = timeoutSeconds > 0
            ? min(timeoutSeconds, ImpulsePoolCarrier.callTimeoutSeconds)
            : nil
        let cancel: () -> Void = self.transport.send(
            endpointKey: ImpulsePoolCarrier.endpointKey,
            method: method,
            data: data,
            timeout: timeout
        ) { (result: Result<Data, Error>) -> Void in
            switch result {
            case .success(let reply):
                completion(.success(reply))
            case .failure(let error):
                completion(.failure(ImpulsePoolCarrier.failure(from: error)))
            }
        }
        return ImpulsePoolCall(onCancel: cancel)
    }


    /// Returns once every block queued before this call has run.
    internal func drainQueue() {
        self.queue.sync {}
    }


    /// Runs one watchdog step now. The timer runs the same step on its own schedule.
    internal func runWatchdogTick() {
        self.queue.sync {
            self.runWatchdog()
        }
    }


    /// Records the disconnect the SDK reported. The session ended when the code is the unauthorized one.
    internal func handleMainDisconnected(code: UInt32) {
        self.queue.async {
            self.sessionEnded = code == ImpulsePoolCarrier.unauthorizedDisconnectCode
        }
    }


    /// The configuration of the main client when none is injected: the socket policy (reconnect backoff from 1 to 30 seconds,
    /// the ping watchdog) under `clientName`, with no token. The native socket connects through the route of
    /// `routeSource`, or directly when there is none.
    internal static func makeMainConfig(
        routeSource: ImpulseProxyRouteSource? = nil,
        clientName: String = ImpulsePoolCarrier.clientName
    ) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "", routeSource: routeSource)
        config.name = clientName
        return config
    }


    internal static func createMainClient(
        endpoint: String,
        config: CentrifugeClientConfig,
        delegate: ImpulsePoolMainDelegate
    ) -> CentrifugeClient {
        return CentrifugeClient(
            endpoint: endpoint,
            config: config,
            delegate: delegate
        )
    }


    /// The pool options: one connection, one call in flight on it, a bounded line, no token of any kind.
    internal static func makePoolOptions(
        endpoint: String,
        clientName: String = ImpulsePoolCarrier.clientName
    ) -> CentrifugeRpcPoolOptions {
        let endpoints: (String) -> [String] = { (key: String) -> [String] in
            return [endpoint]
        }
        return CentrifugeRpcPoolOptions(
            endpoints: endpoints,
            name: clientName,
            timeout: ImpulsePoolCarrier.callTimeoutSeconds,
            maxConnectionsPerEndpoint: ImpulsePoolCarrier.maxConnectionsPerEndpoint,
            maxInflightPerConnection: ImpulsePoolCarrier.maxInflightPerConnection,
            maxQueued: ImpulsePoolCarrier.maxQueued,
            idleTimeout: ImpulsePoolCarrier.idleTimeoutSeconds,
            tokenFrom: false,
            token: "",
            tokenGetter: nil
        )
    }


    /// The pool failure of an SDK error. Session events and the main's disconnect keep their own cases; every other
    /// SDK error carries the reply code, or 0 when the failure is not a server reply.
    internal static func failure(from error: Error) -> ImpulsePoolFailure {
        guard let sdkError: CentrifugeError = error as? CentrifugeError else {
            return .carrier(ImpulseSdkFailure.carrierFailure(from: error))
        }
        switch sdkError {
        case .clientDisconnected:
            return .mainDisconnected
        case .unauthorized:
            return .sessionEnded
        default:
            return .carrier(ImpulseSdkFailure.carrierFailure(from: error))
        }
    }


    private func startTimer() {
        guard self.timer == nil else {
            return
        }
        guard let interval: TimeInterval = self.tickInterval else {
            return
        }
        let source: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: self.queue)
        let period: DispatchTimeInterval = DispatchTimeInterval.milliseconds(Int(interval * 1000.0))
        source.schedule(
            deadline: DispatchTime.now() + interval,
            repeating: period,
            leeway: DispatchTimeInterval.milliseconds(100)
        )
        source.setEventHandler { [weak self] () -> Void in
            self?.runWatchdog()
        }
        source.resume()
        self.timer = source
    }


    /// One watchdog step, on the queue. It does nothing unless the pool is wanted and the main is disconnected.
    private func runWatchdog() {
        guard self.wanted else {
            return
        }
        guard self.main.state == .disconnected else {
            return
        }
        if self.sessionEnded {
            self.renewIdentityThenConnect()
            return
        }
        self.connectMain()
    }


    private func connectMain() {
        guard self.wanted else {
            return
        }
        guard self.main.state == .disconnected else {
            return
        }
        self.mainResetPending = false
        self.main.connect()
    }


    private func renewIdentityThenConnect() {
        guard !self.renewalInFlight else {
            return
        }
        guard self.clock() >= self.renewalRetryAtNanos else {
            return
        }
        self.renewalInFlight = true
        self.identityRenewal { [weak self] (result: Result<Void, Error>) -> Void in
            guard let carrier: ImpulsePoolCarrier = self else {
                return
            }
            carrier.queue.async {
                carrier.renewalFinished(result)
            }
        }
    }


    private func renewalFinished(_ result: Result<Void, Error>) {
        self.renewalInFlight = false
        switch result {
        case .success:
            self.sessionEnded = false
            self.connectMain()
        case .failure:
            self.renewalRetryAtNanos = self.clock() + ImpulsePoolCarrier.nanos(seconds: ImpulsePoolCarrier.renewalRetrySeconds)
        }
    }


    private static func nowNanos() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds
    }


    private static func nanos(seconds: TimeInterval) -> UInt64 {
        return UInt64(seconds * 1_000_000_000.0)
    }
}
