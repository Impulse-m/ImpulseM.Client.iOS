import Foundation
import Security


/// Lifecycle of the managed Xray core. The runtime is exposed only while RUNNING.
public enum ProxyStatus: Equatable, Sendable {
    case off
    case starting
    case running
    case failed
}


/// Error codes stored by the controller and shown by the UI. Values match the proxy error codes of the libXray flow.
public enum ProxyErrorCodes {
    public static let noServer: String = "err:noServer"
    public static let invalidConfig: String = "err:invalidConfig"
    public static let coreStart: String = "err:coreStart"
    public static let coreError: String = "err:coreError"
    public static let coreStopped: String = HealthPolicy.coreStoppedError
}


/// Failures raised inside the controller start sequence. Each one is reported with the code of its stage.
public enum ProxyControllerError: Error, Equatable, Sendable {
    case notEnoughPorts
    case randomUnavailable
}


/// The loopback endpoints and credentials of a running core, published together in one write.
public struct ProxyRuntime: Equatable, Sendable {
    /// The HTTP inbound used by the main transport, with the per-start credentials.
    public let httpAccess: ProxyAccess
    /// The SOCKS5 inbound used by the calls transport. It shares the per-start credentials.
    public let socksEndpoint: ProxyEndpoint


    public init(
        httpAccess: ProxyAccess,
        socksEndpoint: ProxyEndpoint
    ) {
        self.httpAccess = httpAccess
        self.socksEndpoint = socksEndpoint
    }
}


/// The libXray calls the controller needs. The production implementation is `LibXrayCoreDriver`; tests use fakes.
/// Implementations are called only from the controller worker.
public protocol XrayCoreDriver: Sendable {
    func isRunning() throws -> Bool

    func stop() throws

    func freePorts(
        count: Int
    ) throws -> [Int]

    func test(
        configJSON: String
    ) throws

    func run(
        configJSON: String
    ) throws
}


/// Production driver: the libXray JSON Invoke methods, through the shared typed client.
public final class LibXrayCoreDriver: XrayCoreDriver {
    private let client: LibXrayClient


    public init(
        client: LibXrayClient
    ) {
        self.client = client
    }


    public func isRunning() throws -> Bool {
        let method: String = "getXrayState"
        let data: Any? = try client.call(
            method: method,
            payload: nil
        )
        guard let object: [String: Any] = data as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let running: Bool = object["running"] as? Bool else {
            throw LibXrayError.malformedResponse(method: method)
        }
        return running
    }


    public func stop() throws {
        _ = try client.call(
            method: "stopXray",
            payload: nil
        )
    }


    public func freePorts(
        count: Int
    ) throws -> [Int] {
        let method: String = "getFreePorts"
        let payload: [String: Any] = ["count": count]
        let data: Any? = try client.call(
            method: method,
            payload: payload
        )
        guard let object: [String: Any] = data as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let rawPorts: [Any] = object["ports"] as? [Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        var ports: [Int] = []
        for raw: Any in rawPorts {
            guard let port: Int = raw as? Int else {
                throw LibXrayError.malformedResponse(method: method)
            }
            ports.append(port)
        }
        return ports
    }


    public func test(
        configJSON: String
    ) throws {
        let payload: [String: Any] = ["xrayJson": configJSON]
        _ = try client.call(
            method: "testXray",
            payload: payload
        )
    }


    public func run(
        configJSON: String
    ) throws {
        let payload: [String: Any] = ["xrayJson": configJSON]
        _ = try client.call(
            method: "runXray",
            payload: payload
        )
    }
}


/// Owns the user's VLESS settings and the in-process Xray core: the status, the restart sequence, the health check
/// and the route epoch that tells the transport when its routing or its core runtime changed.
/// Every libXray call runs on one serial worker. A lock guards the published fields and is never held during a libXray call.
public final class ProxyController: XrayCoreLifecycle, @unchecked Sendable {
    /// Receives the new epoch after the route or the core runtime changed. Runs on the thread that made the change,
    /// sometimes on the worker, so an observer must stay quick and must not call the controller.
    public typealias EpochObserver = @Sendable (Int) -> Void
    /// Receives the new status each time it changes. Runs on the thread that changed the status.
    public typealias StatusObserver = @Sendable (ProxyStatus) -> Void
    /// Receives the settings after every update, so the owner can store them.
    public typealias Persist = @Sendable (ImpulseProxyState) -> Void
    /// Runs a closure on the worker after a delay in seconds.
    public typealias Scheduler = @Sendable (Double, @escaping @Sendable () -> Void) -> Void


    public var status: ProxyStatus {
        return locked { () -> ProxyStatus in
            return statusValue
        }
    }


    public var lastError: String? {
        return locked { () -> String? in
            return lastErrorValue
        }
    }


    /// The core endpoints; nil unless the core is RUNNING.
    public var runtime: ProxyRuntime? {
        return locked { () -> ProxyRuntime? in
            return statusValue == .running ? runtimeValue : nil
        }
    }


    /// Changes each time the route or the core runtime changes.
    public var epoch: Int {
        return locked { () -> Int in
            return epochValue
        }
    }


    /// The route the main transport must use right now.
    public var route: ProxyRoute {
        return locked { () -> ProxyRoute in
            return ProxyRouting.decide(
                enabled: state.enabled,
                useForTransport: state.useForTransport,
                running: statusValue == .running
            )
        }
    }


    /// A copy of the settings, safe to read and mutate off the lock.
    public var snapshot: ImpulseProxyState {
        return locked { () -> ImpulseProxyState in
            return state
        }
    }


    private static let loopbackHost: String = "127.0.0.1"
    private static let portCount: Int = 2
    private static let userByteCount: Int = 16
    private static let passwordByteCount: Int = 24

    private struct EpochObserverEntry {
        let identifier: Int
        let observation: ProxyObservation
        let handler: EpochObserver
    }


    private struct StatusObserverEntry {
        let identifier: Int
        let observation: ProxyObservation
        let handler: StatusObserver
    }


    private let lock: NSLock = NSLock()
    private let worker: DispatchQueue
    private let driver: XrayCoreDriver
    private let persistHandler: Persist
    private let scheduler: Scheduler
    private var state: ImpulseProxyState
    private var statusValue: ProxyStatus = .off
    private var lastErrorValue: String?
    private var runtimeValue: ProxyRuntime?
    private var generation: Int = 0
    private var autoRetried: Bool = false
    private var publishedRoute: ProxyRoute
    private var publishedRuntime: ProxyRuntime?
    private var epochValue: Int = 0
    private var publishedStatus: ProxyStatus
    private var nextObserverIdentifier: Int = 0
    private var epochObserverEntries: [EpochObserverEntry] = []
    private var statusObserverEntries: [StatusObserverEntry] = []


    public init(
        initialState: ImpulseProxyState,
        driver: XrayCoreDriver,
        persist: @escaping Persist,
        scheduler: Scheduler? = nil
    ) {
        let workerQueue: DispatchQueue = DispatchQueue(label: "net.impulsem.proxy.controller")
        let defaultScheduler: Scheduler = { (delaySeconds: Double, work: @escaping @Sendable () -> Void) -> Void in
            workerQueue.asyncAfter(
                deadline: .now() + delaySeconds,
                execute: work
            )
        }
        self.worker = workerQueue
        self.driver = driver
        self.persistHandler = persist
        self.scheduler = scheduler ?? defaultScheduler
        let initialStatus: ProxyStatus = initialState.enabled ? ProxyStatus.starting : ProxyStatus.off
        self.state = initialState
        self.statusValue = initialStatus
        self.publishedStatus = initialStatus
        self.publishedRoute = ProxyRouting.decide(
            enabled: initialState.enabled,
            useForTransport: initialState.useForTransport,
            running: false
        )
    }


    /// Registers an observer of the route epoch. Observers must be quick; they run on the thread that changed the state.
    /// Cancel the returned handle to stop the delivery.
    @discardableResult
    public func observeEpoch(
        _ observer: @escaping EpochObserver
    ) -> ProxyObservation {
        let identifier: Int = locked { () -> Int in
            nextObserverIdentifier += 1
            return nextObserverIdentifier
        }
        let observation: ProxyObservation = ProxyObservation(
            onCancel: { [weak self] () -> Void in
                self?.removeEpochObserver(identifier: identifier)
            }
        )
        locked { () -> Void in
            epochObserverEntries.append(
                EpochObserverEntry(
                    identifier: identifier,
                    observation: observation,
                    handler: observer
                )
            )
        }
        return observation
    }


    /// Registers an observer of the status. It is called on each change of the status, not with the current value.
    /// Cancel the returned handle to stop the delivery.
    @discardableResult
    public func observeStatus(
        _ observer: @escaping StatusObserver
    ) -> ProxyObservation {
        let identifier: Int = locked { () -> Int in
            nextObserverIdentifier += 1
            return nextObserverIdentifier
        }
        let observation: ProxyObservation = ProxyObservation(
            onCancel: { [weak self] () -> Void in
                self?.removeStatusObserver(identifier: identifier)
            }
        )
        locked { () -> Void in
            statusObserverEntries.append(
                StatusObserverEntry(
                    identifier: identifier,
                    observation: observation,
                    handler: observer
                )
            )
        }
        return observation
    }


    /// Starts the core when the proxy is enabled. Runs on the worker; returns at once.
    public func startIfEnabled() {
        worker.async { [weak self] () -> Void in
            self?.restartFromScratch()
        }
    }


    /// Applies a settings change. The runtime is cleared at once (fail closed). A change of the enabled flag, the selected
    /// server or a core-affecting advanced setting restarts the core on the worker. Ping-only changes never restart it.
    /// The change closure must not call the controller.
    public func update(
        _ change: (inout ImpulseProxyState) -> Void
    ) {
        var restartNeeded: Bool = false
        var saved: ImpulseProxyState = ImpulseProxyState()
        locked { () -> Void in
            var next: ImpulseProxyState = state
            change(&next)
            restartNeeded = next.enabled != state.enabled || next.selectedId != state.selectedId
            if !restartNeeded && next.enabled && XrayPing.restartRequired(previous: state.advanced, next: next.advanced) {
                restartNeeded = true
            }
            state = next
            saved = next
            if restartNeeded {
                runtimeValue = nil
                statusValue = .starting
                lastErrorValue = nil
            }
        }
        persistHandler(saved)
        if restartNeeded {
            worker.async { [weak self] () -> Void in
                self?.restartFromScratch()
            }
        }
        notifyChanged()
        notifyStatusIfChanged()
    }


    /// Stops the core for a ping round. Clears the runtime at once and cancels the pending health check, so the
    /// check does not restart a core that was stopped on purpose.
    public func stopCore() throws {
        try worker.sync { () throws -> Void in
            try stopCoreWorker()
        }
    }


    /// Runs the full start sequence on the worker and waits for it to finish.
    public func restartCore() {
        worker.sync { () -> Void in
            restartCoreWorker()
        }
    }


    /// Waits until every task queued on the worker so far has finished. Tests use it instead of sleeping.
    func drainWorker() {
        worker.sync { () -> Void in
        }
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }


    // Runs on the worker only.
    private func restartFromScratch() {
        locked { () -> Void in
            autoRetried = false
        }
        restartCoreWorker()
    }


    // Runs on the worker only. Stops the old core, then runs the start sequence.
    private func restartCoreWorker() {
        let generationValue: Int = locked { () -> Int in
            generation += 1
            return generation
        }
        stopRunningCore()
        let snapshotState: ImpulseProxyState = snapshot
        setStatus(
            snapshotState.enabled ? ProxyStatus.starting : ProxyStatus.off,
            error: nil
        )
        if !snapshotState.enabled {
            return
        }
        guard let server: ImpulseProxyState.Server = ProxyController.selectedServer(in: snapshotState) else {
            setStatus(
                .failed,
                error: ProxyErrorCodes.noServer
            )
            return
        }
        var failure: String = ProxyErrorCodes.coreStart
        do {
            let ports: [Int] = try driver.freePorts(count: ProxyController.portCount)
            guard ports.count >= ProxyController.portCount else {
                throw ProxyControllerError.notEnoughPorts
            }
            let user: String = try ProxyController.randomHex(byteCount: ProxyController.userByteCount)
            let password: String = try ProxyController.randomHex(byteCount: ProxyController.passwordByteCount)
            let inbounds: LocalInbounds = LocalInbounds(
                httpPort: ports[0],
                socksPort: ports[1],
                user: user,
                password: password
            )
            failure = ProxyErrorCodes.invalidConfig
            let config: String = try XrayConfigBuilder.build(
                server: server,
                inbounds: inbounds,
                advanced: snapshotState.advanced
            )
            try driver.test(configJSON: config)
            failure = ProxyErrorCodes.coreStart
            try driver.run(configJSON: config)
            let credentials: ProxyCredentials = ProxyCredentials(
                user: user,
                password: password
            )
            let runtimeEndpoints: ProxyRuntime = ProxyRuntime(
                httpAccess: ProxyAccess(
                    endpoint: ProxyEndpoint(
                        host: ProxyController.loopbackHost,
                        port: ports[0]
                    ),
                    credentials: credentials
                ),
                socksEndpoint: ProxyEndpoint(
                    host: ProxyController.loopbackHost,
                    port: ports[1]
                )
            )
            locked { () -> Void in
                runtimeValue = runtimeEndpoints
                statusValue = .running
                lastErrorValue = nil
            }
            notifyChanged()
            notifyStatusIfChanged()
            scheduleHealthCheck(generation: generationValue)
        } catch {
            setStatus(
                .failed,
                error: failure
            )
        }
    }


    // Runs on the worker only.
    private func stopRunningCore() {
        if (try? driver.isRunning()) == true {
            _ = try? driver.stop()
        }
    }


    // Runs on the worker only.
    private func stopCoreWorker() throws {
        locked { () -> Void in
            generation += 1
        }
        var stopError: Error?
        if (try? driver.isRunning()) == true {
            do {
                try driver.stop()
            } catch {
                stopError = error
            }
        }
        if let error: Error = stopError {
            setStatus(
                .failed,
                error: ProxyErrorCodes.coreError
            )
            throw error
        }
        let enabledNow: Bool = locked { () -> Bool in
            return state.enabled
        }
        setStatus(
            enabledNow ? ProxyStatus.starting : ProxyStatus.off,
            error: nil
        )
    }


    // Runs on the worker only.
    private func checkAlive(
        expectedGeneration: Int
    ) {
        let isCurrent: Bool = locked { () -> Bool in
            return expectedGeneration == generation && statusValue == .running
        }
        var alive: Bool = false
        if isCurrent {
            alive = (try? driver.isRunning()) ?? false
        }
        let retried: Bool = locked { () -> Bool in
            return autoRetried
        }
        let action: HealthAction = HealthPolicy.decide(
            current: isCurrent,
            alreadyRetried: retried,
            alive: alive
        )
        if action == .stop {
            return
        }
        if action == .recheck {
            locked { () -> Void in
                autoRetried = false
            }
            scheduleHealthCheck(generation: expectedGeneration)
            return
        }
        if action == .restart {
            locked { () -> Void in
                autoRetried = true
            }
            restartCoreWorker()
            return
        }
        setStatus(
            .failed,
            error: ProxyErrorCodes.coreStopped
        )
    }


    private func scheduleHealthCheck(
        generation expectedGeneration: Int
    ) {
        scheduler(HealthPolicy.checkIntervalSeconds) { [weak self] () -> Void in
            self?.checkAlive(expectedGeneration: expectedGeneration)
        }
    }


    private func setStatus(
        _ newStatus: ProxyStatus,
        error: String?
    ) {
        locked { () -> Void in
            statusValue = newStatus
            lastErrorValue = error
            if newStatus != .running {
                runtimeValue = nil
            }
        }
        notifyChanged()
        notifyStatusIfChanged()
    }


    // Publishes the status to the status observers when it differs from the last status they were given.
    private func notifyStatusIfChanged() {
        var observersToCall: [StatusObserverEntry] = []
        var changedStatus: ProxyStatus = ProxyStatus.off
        var changed: Bool = false
        locked { () -> Void in
            if statusValue == publishedStatus {
                return
            }
            publishedStatus = statusValue
            changedStatus = statusValue
            changed = true
            observersToCall = statusObserverEntries
        }
        if !changed {
            return
        }
        for entry: StatusObserverEntry in observersToCall {
            if entry.observation.isActive {
                entry.handler(changedStatus)
            }
        }
    }


    // Publishes the epoch when the route or the runtime differs from what the transport last saw.
    private func notifyChanged() {
        var observersToCall: [EpochObserverEntry] = []
        var changedEpoch: Int = 0
        var changed: Bool = false
        locked { () -> Void in
            let currentRoute: ProxyRoute = ProxyRouting.decide(
                enabled: state.enabled,
                useForTransport: state.useForTransport,
                running: statusValue == .running
            )
            let currentRuntime: ProxyRuntime? = statusValue == .running ? runtimeValue : nil
            if currentRoute == publishedRoute && currentRuntime == publishedRuntime {
                return
            }
            publishedRoute = currentRoute
            publishedRuntime = currentRuntime
            epochValue += 1
            changedEpoch = epochValue
            changed = true
            observersToCall = epochObserverEntries
        }
        if !changed {
            return
        }
        for entry: EpochObserverEntry in observersToCall {
            if entry.observation.isActive {
                entry.handler(changedEpoch)
            }
        }
    }


    private func removeEpochObserver(
        identifier: Int
    ) {
        locked { () -> Void in
            epochObserverEntries.removeAll { (entry: EpochObserverEntry) -> Bool in
                return entry.identifier == identifier
            }
        }
    }


    private func removeStatusObserver(
        identifier: Int
    ) {
        locked { () -> Void in
            statusObserverEntries.removeAll { (entry: StatusObserverEntry) -> Bool in
                return entry.identifier == identifier
            }
        }
    }


    private static func selectedServer(
        in source: ImpulseProxyState
    ) -> ImpulseProxyState.Server? {
        guard let selectedId: String = source.selectedId else {
            return nil
        }
        var all: [ImpulseProxyState.Server] = source.manual
        for subscription: ImpulseProxyState.Subscription in source.subscriptions {
            all.append(contentsOf: subscription.servers)
        }
        for server: ImpulseProxyState.Server in all {
            if server.id == selectedId {
                return server
            }
        }
        return nil
    }


    private static func randomHex(
        byteCount: Int
    ) throws -> String {
        var bytes: [UInt8] = [UInt8](repeating: 0, count: byteCount)
        let result: Int32 = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard result == errSecSuccess else {
            throw ProxyControllerError.randomUnavailable
        }
        var hex: String = ""
        for byte: UInt8 in bytes {
            hex += String(format: "%02x", byte)
        }
        return hex
    }
}
