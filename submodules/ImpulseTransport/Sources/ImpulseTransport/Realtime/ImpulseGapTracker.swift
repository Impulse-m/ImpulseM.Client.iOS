import Foundation

public final class ImpulseGapTracker: @unchecked Sendable {
    public static let positionDroppedCode: Int = 2502

    private static let userLanePrefix: String = "user:"

    private let lock: NSLock = NSLock()
    private var positionDropped: Set<String> = []


    public init() {
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
        lock.lock()
        defer {
            lock.unlock()
        }

        let dropped: Bool = positionDropped.remove(channel) != nil

        if channel.hasPrefix(ImpulseGapTracker.userLanePrefix) {
            return dropped || !recovered
        }

        return dropped || (wasRecovering && !recovered)
    }
}
