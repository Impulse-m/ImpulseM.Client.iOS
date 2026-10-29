import Foundation


/// Handle of an observer registered on a `ProxyController`. Cancelling it removes the observer, so no change
/// that happens after `cancel()` is delivered to it.
public final class ProxyObservation: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let onCancel: @Sendable () -> Void
    private var activeValue: Bool = true


    /// Whether the observer still receives changes.
    var isActive: Bool {
        return locked { () -> Bool in
            return activeValue
        }
    }


    init(
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.onCancel = onCancel
    }


    /// Stops every later delivery to the observer. Calling it again does nothing.
    public func cancel() {
        let wasActive: Bool = locked { () -> Bool in
            let previous: Bool = activeValue
            activeValue = false
            return previous
        }
        if wasActive {
            onCancel()
        }
    }


    private func locked<T>(
        _ body: () -> T
    ) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}
