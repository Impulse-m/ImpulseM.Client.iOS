/// What the periodic core health check does next.
public enum HealthAction {
    /// The check is stale (newer generation or no longer running): do nothing and stop re-arming.
    case stop
    /// The core is healthy: clear the retry allowance and schedule the next check.
    case recheck
    /// First failure: restart the core once.
    case restart
    /// The core died again after a restart: give up.
    case fail
}


/// Decides the next step of the periodic Xray core health check.
public enum HealthPolicy {
    /// Interval between two health checks of a running core.
    public static let checkIntervalSeconds: Double = 30

    /// Error code reported when the core is still dead after one restart.
    public static let coreStoppedError: String = "err:coreStopped"


    public static func decide(
        current: Bool,
        alreadyRetried: Bool,
        alive: Bool
    ) -> HealthAction {
        if !current {
            return .stop
        }
        if alive {
            return .recheck
        }
        return alreadyRetried ? .fail : .restart
    }
}
