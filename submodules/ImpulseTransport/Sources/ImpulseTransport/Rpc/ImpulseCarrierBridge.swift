import Foundation


/// The settle state of one carrier call. The first settle wins, and a cancel reaches the started call once.
internal final class ImpulseCarrierCallState: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var settled: Bool = false
    private var cancelled: Bool = false
    private var cancelSend: (() -> Void)? = nil


    /// Marks the call settled. True for the first settle only, so the caller resumes once.
    internal func markSettled() -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.settled {
            return false
        }
        self.settled = true
        self.cancelSend = nil
        return true
    }


    /// Keeps the cancel of the started call. A cancel that came first runs it at once.
    internal func attach(_ cancel: @escaping () -> Void) {
        self.lock.lock()
        if self.settled {
            self.lock.unlock()
            return
        }
        if self.cancelled {
            self.lock.unlock()
            cancel()
            return
        }
        self.cancelSend = cancel
        self.lock.unlock()
    }


    /// Cancels the started call, or records the cancel so that the call is cancelled once it starts.
    internal func cancel() {
        self.lock.lock()
        self.cancelled = true
        let cancelSend: (() -> Void)? = self.settled ? nil : self.cancelSend
        self.cancelSend = nil
        self.lock.unlock()
        cancelSend?()
    }
}


/// Runs one callback-based carrier call as an async send. The caller resumes once, with the first completion, and
/// cancelling the task cancels the SDK call.
internal enum ImpulseCarrierBridge {
    /// Starts the call and returns its cancel. `start` runs on the calling task. Its completion may run on any thread.
    internal static func send<Reply>(
        start: @escaping (@escaping (Result<Reply, ImpulseCarrierFailure>) -> Void) -> () -> Void
    ) async -> Result<Reply, ImpulseCarrierFailure> {
        let state: ImpulseCarrierCallState = ImpulseCarrierCallState()
        return await withTaskCancellationHandler(
            operation: { () async -> Result<Reply, ImpulseCarrierFailure> in
                return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Reply, ImpulseCarrierFailure>, Never>) -> Void in
                    let cancel: () -> Void = start { (result: Result<Reply, ImpulseCarrierFailure>) -> Void in
                        if state.markSettled() {
                            continuation.resume(returning: result)
                        }
                    }
                    state.attach(cancel)
                }
            },
            onCancel: {
                state.cancel()
            }
        )
    }
}
