import Foundation


/// The carrier of the token-less pool: the identity methods, sent through an `ImpulsePoolCarrier`. The pool refuses a
/// method it does not serve locally, without sending it.
public final class ImpulsePoolRequestCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let pool: ImpulsePoolCarrier


    /// Creates the carrier over a pool that the app has started.
    public init(pool: ImpulsePoolCarrier) {
        self.pool = pool
    }


    /// Sends one call through the pool, with its deadline. The pool cuts a deadline above its own to its limit.
    public func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let pool: ImpulsePoolCarrier = self.pool
        let payload: Data = Data(data)
        return await ImpulseCarrierBridge.send(start: { (completion: @escaping (Result<[UInt8], ImpulseCarrierFailure>) -> Void) -> () -> Void in
            let call: ImpulsePoolCall = pool.call(
                method: method,
                data: payload,
                timeoutSeconds: timeoutSeconds
            ) { (result: Result<Data, ImpulsePoolFailure>) -> Void in
                switch result {
                case .success(let reply):
                    completion(.success([UInt8](reply)))

                case .failure(let failure):
                    completion(.failure(ImpulsePoolRequestCarrier.carrierFailure(from: failure)))
                }
            }
            return {
                call.cancel()
            }
        })
    }


    /// The carrier failure of a pool failure. A lost main client and an ended session carry no server answer: the pool
    /// renews its identity and reconnects on its own, and the request service retries the call.
    internal static func carrierFailure(from failure: ImpulsePoolFailure) -> ImpulseCarrierFailure {
        switch failure {
        case .mainDisconnected, .sessionEnded:
            return ImpulseSdkFailure.networkFailure

        case .carrier(let carrierFailure):
            return carrierFailure
        }
    }
}
