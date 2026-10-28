import Foundation


/// Why a session ended on the way to a steady connection.
public enum ImpulseConnectionFailure: Equatable, Sendable {
    /// The server refused the session as unrecoverable. The session has been cleared.
    case auth
}


/// The states of the connection, from a fresh start to a steady session.
public enum ImpulseConnectionState: Equatable, Sendable {
    case disconnected
    case connectingIdentity
    case identityReady
    case connectingSession
    case sessionReady
    case refreshing
    case failed(ImpulseConnectionFailure)


    /// The indicator a client shows for this state. Offline always wins; a request in flight turns a ready socket into
    /// `updating`.
    public func indicator(
        networkAvailable: Bool,
        requestInFlight: Bool
    ) -> ImpulseConnectionIndicator {
        if !networkAvailable {
            return .waitingForNetwork
        }

        switch self {
        case .disconnected, .connectingIdentity, .connectingSession, .failed:
            return .connecting

        case .identityReady, .sessionReady:
            return requestInFlight ? .updating : .connected

        case .refreshing:
            return .updating
        }
    }
}


/// The indicator a client shows, independent of the transport that produced it.
public enum ImpulseConnectionIndicator: Equatable, Sendable {
    case waitingForNetwork
    case connecting
    case updating
    case connected
}


/// What happened that may move the connection.
public enum ImpulseConnectionEvent: Equatable, Sendable {
    /// The network path went away. Every state moves to `disconnected`.
    case networkLost
    /// The pool minted an identity. A stored session makes the next state `connectingSession`.
    case mintSucceeded(hasSession: Bool)
    /// The update socket connected and its declaration was acknowledged. For a session this also means the user lane is
    /// subscribed.
    case socketReady
    /// A login completed, or a session was loaded from storage.
    case sessionAvailable
    /// The refresh point passed, or the update socket refused the access token.
    case refreshDue
    /// A refresh returned a fresh session.
    case refreshSucceeded
    /// A refresh was answered with an unrecoverable error.
    case refreshUnrecoverable
}


/// Moves the connection through its states. An event that the current state does not accept leaves the state unchanged.
public struct ImpulseConnectionMachine: Equatable, Sendable {
    public private(set) var state: ImpulseConnectionState


    public init(state: ImpulseConnectionState = .disconnected) {
        self.state = state
    }


    /// Applies an event. Returns true when the event moved the state.
    @discardableResult
    public mutating func apply(_ event: ImpulseConnectionEvent) -> Bool {
        guard let next: ImpulseConnectionState = ImpulseConnectionMachine.transition(from: state, on: event) else {
            return false
        }

        state = next
        return true
    }


    private static func transition(
        from current: ImpulseConnectionState,
        on event: ImpulseConnectionEvent
    ) -> ImpulseConnectionState? {
        switch event {
        case .networkLost:
            return .disconnected

        case .mintSucceeded(let hasSession):
            switch current {
            case .disconnected, .failed:
                return hasSession ? .connectingSession : .connectingIdentity

            default:
                return nil
            }

        case .socketReady:
            switch current {
            case .connectingIdentity:
                return .identityReady

            case .connectingSession:
                return .sessionReady

            default:
                return nil
            }

        case .sessionAvailable:
            switch current {
            case .identityReady:
                return .connectingSession

            default:
                return nil
            }

        case .refreshDue:
            switch current {
            case .sessionReady:
                return .refreshing

            default:
                return nil
            }

        case .refreshSucceeded:
            switch current {
            case .refreshing:
                return .sessionReady

            default:
                return nil
            }

        case .refreshUnrecoverable:
            switch current {
            case .refreshing:
                return .failed(.auth)

            default:
                return nil
            }
        }
    }
}


/// Reconnect delays: 1 s, doubling up to 30 s. A connection that comes up starts again from 1 s.
public struct ImpulseReconnectBackoff: Equatable, Sendable {
    public static let minimumSeconds: TimeInterval = 1
    public static let maximumSeconds: TimeInterval = 30

    private var nextSeconds: TimeInterval


    public init() {
        self.nextSeconds = ImpulseReconnectBackoff.minimumSeconds
    }


    /// Returns the delay before the next reconnect and doubles the delay that follows it, up to 30 s.
    public mutating func nextDelay() -> TimeInterval {
        let delay: TimeInterval = nextSeconds
        nextSeconds = min(nextSeconds * 2, ImpulseReconnectBackoff.maximumSeconds)
        return delay
    }


    /// Starts again from the minimum delay once a connection is established.
    public mutating func reset() {
        nextSeconds = ImpulseReconnectBackoff.minimumSeconds
    }
}


/// The action the connection takes after one sync check.
public struct ImpulseSyncPlan: Equatable, Sendable {
    /// User whose lane must be dropped first, or 0.
    public let dropUserLane: Int64
    /// Stop and clear the channel lanes.
    public let stopLanes: Bool
    /// Drop the socket before any connect. Offline always disconnects.
    public let disconnect: Bool
    /// User whose lane must be subscribed, or 0.
    public let subscribeUserLane: Int64
    public let connect: Bool


    public init(
        dropUserLane: Int64,
        stopLanes: Bool,
        disconnect: Bool,
        subscribeUserLane: Int64,
        connect: Bool
    ) {
        self.dropUserLane = dropUserLane
        self.stopLanes = stopLanes
        self.disconnect = disconnect
        self.subscribeUserLane = subscribeUserLane
        self.connect = connect
    }
}


/// Turns the observed login and network state into connection actions. Runs at start and then every
/// `syncIntervalSeconds`. The remembered state changes inside one actor call, so overlapping callers see each change once.
public actor ImpulseSyncPlanner {
    public static let syncIntervalSeconds: TimeInterval = 5

    private enum SocketKind {
        case identity
        case session
    }


    private var laneUserId: Int64 = 0
    private var wasOnline: Bool = true
    /// The kind the socket last connected with. Nil until the first online plan.
    private var connectedKind: SocketKind?


    public init() {
    }


    /// Plans the next action. A returning network, a switched user or a new credential kind asks for a rekey: the
    /// socket drops first, skipping the backoff. The very first connect is not a rekey.
    public func plan(
        userId: Int64,
        sessionPresent: Bool,
        online: Bool
    ) -> ImpulseSyncPlan {
        let loggedIn: Bool = userId != 0 && sessionPresent
        let cameBack: Bool = online && !wasOnline
        wasOnline = online

        let previous: Int64 = laneUserId
        laneUserId = loggedIn ? userId : 0
        let drop: Int64 = (previous != 0 && previous != laneUserId) ? previous : 0
        let stopLanes: Bool = !loggedIn || drop != 0
        let subscribe: Int64 = loggedIn ? userId : 0

        if !online {
            return ImpulseSyncPlan(
                dropUserLane: drop,
                stopLanes: stopLanes,
                disconnect: true,
                subscribeUserLane: 0,
                connect: false
            )
        }

        let kind: SocketKind = sessionPresent ? .session : .identity
        let kindChanged: Bool = connectedKind != nil && connectedKind != kind
        connectedKind = kind

        let rekey: Bool = cameBack || drop != 0 || kindChanged
        return ImpulseSyncPlan(
            dropUserLane: drop,
            stopLanes: stopLanes,
            disconnect: rekey,
            subscribeUserLane: subscribe,
            connect: true
        )
    }
}
