/// The route of a LiveKit call's media on macOS.
public enum LiveKitCallRoute: Equatable {
    /// The call connects straight to LiveKit without a proxy.
    case direct

    /// The call connects through the calls tunnel of the proxy core.
    case tunnelled

    /// The call must not start. The tunnel is required but cannot be used, so the call never falls back to a direct route.
    case blocked
}


/// Decides how the media of a LiveKit call reaches its server.
///
/// Until the loopback signalling relay has passed its spike, every call is direct and the proxied-calls toggle stays hidden.
public struct LiveKitProxyGate {
    /// Set to true only after the loopback signalling relay has passed its spike on macOS.
    public static let defaultSpikePassed: Bool = false


    public let spikePassed: Bool


    public init(spikePassed: Bool = LiveKitProxyGate.defaultSpikePassed) {
        self.spikePassed = spikePassed
    }


    /// Whether the proxied-calls toggle is shown in the proxy UI.
    public var callsToggleVisible: Bool {
        return spikePassed
    }


    /// Returns the route of a call.
    ///
    /// - Parameters:
    ///   - proxyEnabled: the master proxy switch.
    ///   - useForCalls: the calls toggle of the proxy state.
    ///   - coreRunning: whether the proxy core is RUNNING.
    ///   - relayFailed: whether the tunnelled media relay could not be set up.
    public func route(
        proxyEnabled: Bool,
        useForCalls: Bool,
        coreRunning: Bool,
        relayFailed: Bool
    ) -> LiveKitCallRoute {
        guard spikePassed else {
            return .direct
        }
        guard proxyEnabled && useForCalls else {
            return .direct
        }
        guard coreRunning && !relayFailed else {
            return .blocked
        }
        return .tunnelled
    }
}
