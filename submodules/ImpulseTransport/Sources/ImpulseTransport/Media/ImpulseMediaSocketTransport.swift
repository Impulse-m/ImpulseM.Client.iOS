import Foundation
import SwiftCentrifuge


/// The rpc calls and the lifecycle of one SDK client. The SDK client implements it; tests use a double.
internal protocol ImpulseMediaClient: AnyObject {
    /// Starts the connection. Calling it again while the client is connecting or connected changes nothing.
    func connect()

    /// Sends one rpc with its options. The completion runs once. The returned closure cancels the call.
    func sendRpc(
        method: String,
        data: Data,
        options: CentrifugeRpcOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) -> () -> Void

    /// Closes the connection. Calls still on it settle through their completions.
    func disconnect()
}


extension CentrifugeClient: ImpulseMediaClient {
    internal func sendRpc(
        method: String,
        data: Data,
        options: CentrifugeRpcOptions,
        completion: @escaping (Result<CentrifugeRpcResult, Error>) -> Void
    ) -> () -> Void {
        let call: CentrifugeRpcCall = self.rpc(
            method: method,
            data: data,
            options: options,
            completion: completion
        )
        return {
            call.cancel()
        }
    }
}


/// The media transport of one media endpoint: a SwiftCentrifuge client that carries the media calls to it.
///
/// The client connects on the first call and stays connected until `close()`. Its connection carries the session
/// token that `tokenGetter` supplies, as the Android media fleet does. Its reconnect backoff is 1 to 30 seconds and its
/// ping watchdog follows the SDK's server ping delay. A call deadline above `ImpulseMediaFleet.callTimeoutSeconds` is
/// cut to it, because the SDK refuses a deadline above the client's own timeout.
///
/// Completions run on the SDK's queue, or on the caller's thread for a call refused after `close()`. The transport is
/// thread-safe.
public final class ImpulseMediaSocketTransport: ImpulseMediaTransport, @unchecked Sendable {
    /// The smallest reconnect delay of the client, in seconds.
    public static let minReconnectDelaySeconds: Double = 1.0
    /// The largest reconnect delay of the client, in seconds.
    public static let maxReconnectDelaySeconds: Double = 30.0
    /// The largest server ping delay the client allows, in seconds (the SDK default).
    public static let maxServerPingDelaySeconds: Double = 10.0

    private let client: ImpulseMediaClient
    private let lock: NSLock = NSLock()
    private var connectRequested: Bool = false
    private var closed: Bool = false


    /// Creates the transport of `endpoint` with a new SDK client that takes its connection token from `tokenGetter`.
    /// The client's native WebSocket connects through the route of `routeSource`, or directly when it is nil.
    public convenience init(
        endpoint: String,
        tokenGetter: @escaping CentrifugeConnectionTokenGetter,
        routeSource: ImpulseProxyRouteSource? = nil
    ) {
        let client: CentrifugeClient = CentrifugeClient(
            endpoint: endpoint,
            config: ImpulseMediaSocketTransport.makeConfig(
                tokenGetter: tokenGetter,
                routeSource: routeSource
            )
        )
        self.init(client: client)
    }


    internal init(client: ImpulseMediaClient) {
        self.client = client
    }


    /// Sends one media call through the client. The completion runs once. A call made after `close()` fails at once
    /// with a network failure, and nothing is sent.
    public func send(
        method: String,
        data: Data,
        timeoutSeconds: TimeInterval,
        completion: @escaping (Result<Data, ImpulseCarrierFailure>) -> Void
    ) -> () -> Void {
        guard self.connectIfOpen() else {
            completion(.failure(ImpulseSdkFailure.networkFailure))
            return {}
        }
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(
            headers: [:],
            timeout: ImpulseMediaSocketTransport.deadline(seconds: timeoutSeconds)
        )
        return self.client.sendRpc(
            method: method,
            data: data,
            options: options
        ) { (result: Result<CentrifugeRpcResult, Error>) -> Void in
            switch result {
            case .success(let reply):
                completion(.success(reply.data))

            case .failure(let error):
                completion(.failure(ImpulseSdkFailure.carrierFailure(from: error)))
            }
        }
    }


    /// Closes the client. The transport sends no call afterwards.
    public func close() {
        self.lock.lock()
        let wasClosed: Bool = self.closed
        self.closed = true
        self.lock.unlock()
        if !wasClosed {
            self.client.disconnect()
        }
    }


    /// The configuration of the media client: the 1 to 30 second reconnect backoff, the ping delay, the media call
    /// timeout, the session token and the native WebSocket. The native WebSocket is the only one that accepts the route
    /// provider, so every media client uses it, with or without a route.
    internal static func makeConfig(
        tokenGetter: @escaping CentrifugeConnectionTokenGetter,
        routeSource: ImpulseProxyRouteSource? = nil
    ) -> CentrifugeClientConfig {
        return CentrifugeClientConfig(
            timeout: ImpulseMediaFleet.callTimeoutSeconds,
            minReconnectDelay: ImpulseMediaSocketTransport.minReconnectDelaySeconds,
            maxReconnectDelay: ImpulseMediaSocketTransport.maxReconnectDelaySeconds,
            maxServerPingDelay: ImpulseMediaSocketTransport.maxServerPingDelaySeconds,
            name: ImpulsePoolCarrier.clientName,
            useNativeWebSocket: true,
            urlSessionConfigurationProvider: ImpulseSocketPolicy.urlSessionConfigurationProvider(routeSource: routeSource),
            tokenGetter: tokenGetter
        )
    }


    /// The SDK deadline of a call: the requested seconds cut to the media call timeout, or nil for the client's own
    /// timeout when none is requested.
    internal static func deadline(seconds: TimeInterval) -> TimeInterval? {
        guard seconds > 0 else {
            return nil
        }
        return min(seconds, ImpulseMediaFleet.callTimeoutSeconds)
    }


    /// Starts the connection on the first call. False when the transport is closed.
    private func connectIfOpen() -> Bool {
        self.lock.lock()
        let isOpen: Bool = !self.closed
        let needsConnect: Bool = isOpen && !self.connectRequested
        if needsConnect {
            self.connectRequested = true
        }
        self.lock.unlock()
        if needsConnect {
            self.client.connect()
        }
        return isOpen
    }
}
