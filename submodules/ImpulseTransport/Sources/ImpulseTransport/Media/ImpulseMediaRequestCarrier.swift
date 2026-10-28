import Foundation


/// The carrier of the media fleet: the media methods, sent to the media endpoint of this DC. The fleet holds the calls
/// that wait for the config and enforces the limits of the endpoint.
public final class ImpulseMediaRequestCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let fleet: ImpulseMediaFleet


    /// Creates the carrier over a fleet that the app configures.
    public init(fleet: ImpulseMediaFleet) {
        self.fleet = fleet
    }


    /// Sends one media call. The fleet cuts a deadline above its media deadline to it.
    public func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let fleet: ImpulseMediaFleet = self.fleet
        let payload: Data = Data(data)
        return await ImpulseCarrierBridge.send(start: { (completion: @escaping (Result<[UInt8], ImpulseCarrierFailure>) -> Void) -> () -> Void in
            let call: ImpulseMediaCall = fleet.call(
                method: method,
                data: payload,
                timeoutSeconds: timeoutSeconds
            ) { (result: Result<Data, ImpulseMediaFailure>) -> Void in
                switch result {
                case .success(let reply):
                    completion(.success([UInt8](reply)))

                case .failure(let failure):
                    completion(.failure(ImpulseMediaRequestCarrier.carrierFailure(from: failure)))
                }
            }
            return {
                call.cancel()
            }
        })
    }


    /// The carrier failure of a fleet failure. A failure of the media carrier keeps its own codes. A refusal of the fleet
    /// (no config yet, a closed fleet, a full queue, an oversized request) has no server answer, so it is a network
    /// failure, as the Android fleet reports it.
    internal static func carrierFailure(from failure: ImpulseMediaFailure) -> ImpulseCarrierFailure {
        switch failure {
        case .carrier(let carrierFailure):
            return carrierFailure

        case .noConfig, .closed, .requestTooLarge, .queueFull:
            return ImpulseSdkFailure.networkFailure
        }
    }
}
