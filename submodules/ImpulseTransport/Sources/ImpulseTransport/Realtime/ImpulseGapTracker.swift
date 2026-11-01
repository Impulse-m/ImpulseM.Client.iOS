import Foundation

public final class ImpulseGapTracker: @unchecked Sendable {
    public static let positionDroppedCode: Int = 2502

    private static let userLanePrefix: String = "user:"

    private let lock: NSLock = NSLock()
    private var positionDropped: Set<String> = []
    private var reconnectPending: Bool = false


    public init() {
    }


    /// Records a reconnect of the update socket. Nothing is requested here: the first user lane subscribe after it spends the
    /// mark, so the difference runs once the user lane is back and the subscribe that follows is not asked for a second one.
    public func onReconnected() {
        lock.lock()
        defer {
            lock.unlock()
        }

        reconnectPending = true
    }


    public func onUnsubscribed(channel: String, code: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }

        if code == ImpulseGapTracker.positionDroppedCode {
            positionDropped.insert(channel)
        } else {
            positionDropped.remove(channel)
        }
    }


    /// Returns true when the application must run a difference for this lane.
    public func onSubscribed(channel: String, recovered: Bool, wasRecovering: Bool) -> Bool {
        return differenceReason(channel: channel, recovered: recovered, wasRecovering: wasRecovering) != nil
    }


    /// Returns the reason of the difference this lane needs, or nil when it needs none. A user lane subscribe spends a pending
    /// reconnect: a recovered subscribe then asks once with `socketReconnected`.
    public func differenceReason(
        channel: String,
        recovered: Bool,
        wasRecovering: Bool
    ) -> ImpulseDifferenceReason? {
        lock.lock()
        defer {
            lock.unlock()
        }

        let dropped: Bool = positionDropped.remove(channel) != nil

        if channel.hasPrefix(ImpulseGapTracker.userLanePrefix) {
            let reconnect: Bool = reconnectPending
            reconnectPending = false

            if dropped || !recovered {
                return recovered ? .subscribePositionDropped : .subscribeNotRecovered
            }

            if reconnect {
                return ImpulseDifferenceReason.socketReconnected
            }

            return nil
        }

        if dropped || (wasRecovering && !recovered) {
            return recovered ? .subscribePositionDropped : .subscribeNotRecovered
        }

        return nil
    }
}
