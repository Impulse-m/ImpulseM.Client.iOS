import Foundation


/// Why a media call did not succeed.
public enum ImpulseMediaFailure: Error, Equatable {
    /// The media endpoint of this DC is not known: the config is not published yet, or it has no media option for it.
    case noConfig(method: String)
    /// The fleet is closed and accepts no call.
    case closed
    /// The request is larger than the media request cap.
    case requestTooLarge(bytes: Int)
    /// The calls that wait for the config are full.
    case queueFull
    /// A failure of the media carrier, as the carrier reported it.
    case carrier(ImpulseCarrierFailure)


    /// The text of the failure. The no-config text names the method, as the media fleet reports it.
    public var text: String {
        switch self {
        case .noConfig(let method):
            return "no config yet for \(method)"
        case .closed:
            return "media fleet is closed"
        case .requestTooLarge(let bytes):
            return "media request is \(bytes) bytes, over the cap"
        case .queueFull:
            return "media fleet queue is full"
        case .carrier:
            return "media carrier failure"
        }
    }
}


/// Handle of one media call. `cancel()` stops the call; calling it after the call settled does nothing.
public struct ImpulseMediaCall {
    private let onCancel: () -> Void


    internal init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }


    public func cancel() {
        self.onCancel()
    }
}


/// The carrier of one media endpoint: the pool that sends the calls to it.
public protocol ImpulseMediaTransport: AnyObject {
    /// Sends one call with its own timeout. The completion runs once, on any thread. The returned closure cancels the call.
    func send(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseCarrierFailure>) -> Void
    ) -> () -> Void

    /// Stops the carrier. Calls still in flight settle through their completions.
    func close()
}


/// Builds the carrier of one media endpoint URL. The carrier is built with the fleet's limits.
public typealias ImpulseMediaTransportFactory = (String) -> ImpulseMediaTransport


/// One call of the fleet: the method, its body, its deadline, and the completion that settles it once.
private final class ImpulseMediaCallState {
    let method: String
    let data: Data
    let timeoutSeconds: TimeInterval
    let completion: (Result<Data, ImpulseMediaFailure>) -> Void
    var settled: Bool = false
    var cancelSend: (() -> Void)? = nil


    init(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseMediaFailure>) -> Void
    ) {
        self.method = method
        self.data = data
        self.timeoutSeconds = timeoutSeconds
        self.completion = completion
    }
}


/// The media fleet of this DC: calls of the four media methods go to the media endpoint from the config's media option
/// of this DC. Calls made before the config is published wait for it, each up to its own deadline, and fail with
/// `no config yet for <method>` when none comes. A call made with no media option for this DC fails at once with the same
/// text. The fleet never falls back to the update socket.
///
/// The carrier of the endpoint enforces the connection limits (`connectionsPerEndpoint`, `inflightPerConnection`).
/// Completions run on the fleet's queue, local refusals included. The fleet is thread-safe.
public final class ImpulseMediaFleet {
    /// Connections the media endpoint takes at most.
    public static let connectionsPerEndpoint: Int = 2
    /// Calls in flight on each connection at most.
    public static let inflightPerConnection: Int = 2
    /// Calls that wait for the config at most.
    public static let maxQueued: Int = 64
    /// Deadline of a media call, in seconds. A call asks for at most this.
    public static let callTimeoutSeconds: TimeInterval = 10.0
    /// Largest request body the media endpoint accepts, in bytes (its message size limit).
    public static let requestByteCap: Int = 557_056
    /// Size of one upload part, in bytes.
    public static let partBytes: Int = 512 * 1024

    private static let cancelledSdkCode: Int = 17

    private let queue: DispatchQueue = DispatchQueue(label: "net.impulsem.transport.media-fleet")
    private let makeTransport: ImpulseMediaTransportFactory
    private let deadlineSeconds: TimeInterval
    private var waiting: [ImpulseMediaCallState] = []
    private var published: Bool = false
    private var closed: Bool = false
    private var endpoint: String? = nil
    private var transport: ImpulseMediaTransport? = nil


    /// Creates a fleet that builds its carrier with `makeTransport` when the first call needs one.
    public init(makeTransport: @escaping ImpulseMediaTransportFactory) {
        self.makeTransport = makeTransport
        self.deadlineSeconds = ImpulseMediaFleet.callTimeoutSeconds
    }


    internal init(
        makeTransport: @escaping ImpulseMediaTransportFactory,
        deadlineSeconds: TimeInterval
    ) {
        self.makeTransport = makeTransport
        self.deadlineSeconds = deadlineSeconds
    }


    /// Publishes the config. The endpoint is the media option of `thisDc`, or nil when the config has none. The first
    /// publication sends the calls that waited for it. A change of endpoint retires the carrier of the old one.
    public func setConfig(
        dcOptions: [ImpulseDcOption],
        thisDc: Int32
    ) {
        let endpoint: String? = ImpulseEndpoints.mediaUrl(dcOptions: dcOptions, thisDc: thisDc)
        self.queue.async {
            self.publish(endpoint)
        }
    }


    /// Sends a media call. A deadline above `callTimeoutSeconds` is cut to it; zero or less means `callTimeoutSeconds`.
    /// The completion runs once.
    public func call(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseMediaFailure>) -> Void
    ) -> ImpulseMediaCall {
        let deadline: TimeInterval = timeoutSeconds > 0
            ? min(timeoutSeconds, self.deadlineSeconds)
            : self.deadlineSeconds
        let state: ImpulseMediaCallState = ImpulseMediaCallState(
            method: method,
            data: data,
            timeoutSeconds: deadline,
            completion: completion
        )
        self.queue.async {
            self.admit(state)
        }
        return ImpulseMediaCall(onCancel: { [weak self] () -> Void in
            guard let fleet: ImpulseMediaFleet = self else {
                return
            }
            fleet.queue.async {
                fleet.cancel(state)
            }
        })
    }


    /// Closes the fleet: the waiting calls fail, the carrier closes, and the fleet accepts no call afterwards.
    public func close() {
        self.queue.async {
            self.closeOnQueue()
        }
    }


    /// Returns once every block queued before this call has run.
    internal func drainQueue() {
        self.queue.sync {}
    }


    private func admit(_ state: ImpulseMediaCallState) {
        if self.closed {
            self.settle(state, .failure(.closed))
            return
        }
        if state.data.count > ImpulseMediaFleet.requestByteCap {
            self.settle(state, .failure(.requestTooLarge(bytes: state.data.count)))
            return
        }
        if !self.published {
            if self.waiting.count >= ImpulseMediaFleet.maxQueued {
                self.settle(state, .failure(.queueFull))
                return
            }
            self.waiting.append(state)
            self.armExpiry(state)
            return
        }
        self.dispatch(state)
    }


    private func publish(_ endpoint: String?) {
        guard !self.closed else {
            return
        }
        let first: Bool = !self.published
        self.published = true
        if !first && self.endpoint == endpoint {
            return
        }
        self.endpoint = endpoint
        let retired: ImpulseMediaTransport? = self.transport
        self.transport = nil
        retired?.close()
        if first {
            let flushed: [ImpulseMediaCallState] = self.waiting
            self.waiting = []
            for state: ImpulseMediaCallState in flushed {
                self.dispatch(state)
            }
        }
    }


    private func dispatch(_ state: ImpulseMediaCallState) {
        guard let endpoint: String = self.endpoint else {
            self.settle(state, .failure(.noConfig(method: state.method)))
            return
        }
        let carrier: ImpulseMediaTransport = self.transportFor(endpoint)
        state.cancelSend = carrier.send(
            method: state.method,
            data: state.data,
            timeoutSeconds: state.timeoutSeconds
        ) { (result: Result<Data, ImpulseCarrierFailure>) -> Void in
            self.queue.async {
                self.finish(state, result)
            }
        }
    }


    private func transportFor(_ endpoint: String) -> ImpulseMediaTransport {
        if let existing: ImpulseMediaTransport = self.transport {
            return existing
        }
        let created: ImpulseMediaTransport = self.makeTransport(endpoint)
        self.transport = created
        return created
    }


    private func armExpiry(_ state: ImpulseMediaCallState) {
        let deadline: DispatchTime = DispatchTime.now() + state.timeoutSeconds
        self.queue.asyncAfter(deadline: deadline) {
            self.expire(state)
        }
    }


    /// Fails a call that still waits for the config when its deadline comes. A call already sent is not touched here.
    private func expire(_ state: ImpulseMediaCallState) {
        guard self.removeWaiting(state) else {
            return
        }
        self.settle(state, .failure(.noConfig(method: state.method)))
    }


    private func cancel(_ state: ImpulseMediaCallState) {
        if self.removeWaiting(state) {
            let cancelled: ImpulseCarrierFailure = ImpulseCarrierFailure(
                sdkCode: ImpulseMediaFleet.cancelledSdkCode,
                appCode: 0,
                appType: "",
                metadata: [:]
            )
            self.settle(state, .failure(.carrier(cancelled)))
            return
        }
        state.cancelSend?()
    }


    private func closeOnQueue() {
        guard !self.closed else {
            return
        }
        self.closed = true
        let retired: ImpulseMediaTransport? = self.transport
        self.transport = nil
        let drained: [ImpulseMediaCallState] = self.waiting
        self.waiting = []
        retired?.close()
        for state: ImpulseMediaCallState in drained {
            self.settle(state, .failure(.closed))
        }
    }


    private func finish(
        _ state: ImpulseMediaCallState,
        _ result: Result<Data, ImpulseCarrierFailure>
    ) {
        switch result {
        case .success(let reply):
            self.settle(state, .success(reply))
        case .failure(let failure):
            self.settle(state, .failure(.carrier(failure)))
        }
    }


    /// Takes the call out of the queue of calls waiting for the config. False when it is not waiting there.
    private func removeWaiting(_ state: ImpulseMediaCallState) -> Bool {
        guard let index: Int = self.waiting.firstIndex(where: { (candidate: ImpulseMediaCallState) -> Bool in
            return candidate === state
        }) else {
            return false
        }
        self.waiting.remove(at: index)
        return true
    }


    private func settle(
        _ state: ImpulseMediaCallState,
        _ result: Result<Data, ImpulseMediaFailure>
    ) {
        guard !state.settled else {
            return
        }
        state.settled = true
        state.cancelSend = nil
        state.completion(result)
    }
}
