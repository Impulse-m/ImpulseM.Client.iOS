import Foundation
import SwiftCentrifuge


/// The rpc calls of one update socket connection. The SDK client implements it; tests use a double.
internal protocol ImpulseUpdateTransport: AnyObject {
    /// Sends one rpc with its deadline. The completion runs once, on any thread. The returned closure cancels the call.
    func send(
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void
}


extension CentrifugeClient: ImpulseUpdateTransport {
    internal func send(
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        let options: CentrifugeRpcOptions = CentrifugeRpcOptions(
            headers: [:],
            timeout: timeout
        )
        let call: CentrifugeRpcCall = self.rpc(
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


/// The carrier of the update socket: the RPC calls of the account's connection, which also carries the realtime lanes.
///
/// The SDK refuses a call deadline above the client's own timeout, so the client must be created with a timeout of at
/// least `ImpulseRequestTimeouts.updateCallSeconds`. Completions run on the SDK's queue.
public final class ImpulseUpdateSocketCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let transport: any ImpulseUpdateTransport


    /// The configuration of an update socket client when none is given: the reconnect backoff, the ping watchdog and the
    /// native WebSocket transport of `ImpulseSocketPolicy`, with the timeout of the update calls. The token is left empty.
    /// A nil `routeSource` gives the direct connection; a source makes each connection use its current route.
    public static func defaultClientConfig(routeSource: ImpulseProxyRouteSource? = nil) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "", routeSource: routeSource)
        config.timeout = ImpulseRequestTimeouts.updateCallSeconds
        return config
    }


    /// Creates the SDK client of the update socket. `config` replaces `defaultClientConfig()` when given; a config with a
    /// timeout below `ImpulseRequestTimeouts.updateCallSeconds` makes the update calls fail, so keep it at least that.
    public static func makeClient(
        endpoint: String,
        config: CentrifugeClientConfig? = nil,
        delegate: CentrifugeClientDelegate? = nil
    ) -> CentrifugeClient {
        return CentrifugeClient(
            endpoint: endpoint,
            config: ImpulseUpdateSocketCarrier.resolveClientConfig(config),
            delegate: delegate
        )
    }


    /// Creates the carrier on the SDK client of the update socket.
    public init(client: CentrifugeClient) {
        self.transport = client
    }


    internal init(transport: any ImpulseUpdateTransport) {
        self.transport = transport
    }


    /// Sends one call. A deadline above the update call deadline is cut to it; a deadline of zero or less means it.
    public func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let timeout: TimeInterval? = ImpulseUpdateSocketCarrier.deadline(seconds: timeoutSeconds)
        let payload: Data = Data(data)
        let transport: any ImpulseUpdateTransport = self.transport
        return await ImpulseCarrierBridge.send(start: { (completion: @escaping (Result<[UInt8], ImpulseCarrierFailure>) -> Void) -> () -> Void in
            return transport.send(method: method, data: payload, timeout: timeout) { (result: Result<Data, Error>) -> Void in
                switch result {
                case .success(let reply):
                    completion(.success([UInt8](reply)))

                case .failure(let error):
                    completion(.failure(ImpulseSdkFailure.carrierFailure(from: error)))
                }
            }
        })
    }


    /// The configuration a client is created with: the given one, or the default one.
    internal static func resolveClientConfig(_ config: CentrifugeClientConfig?) -> CentrifugeClientConfig {
        return config ?? ImpulseUpdateSocketCarrier.defaultClientConfig()
    }


    /// The SDK deadline of a call: the requested seconds cut to the update call deadline, or nil for the client's own
    /// timeout when none is requested.
    private static func deadline(seconds: TimeInterval) -> TimeInterval? {
        guard seconds > 0 else {
            return nil
        }
        return min(seconds, ImpulseRequestTimeouts.updateCallSeconds)
    }
}
