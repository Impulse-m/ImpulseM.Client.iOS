import XCTest
import SwiftSignalKit
import TelegramCore
@testable import ImpulseNetworkEngine

/// Counts the completions of one request. The queue that runs them is the only writer, and the tests read it after a flush.
final class ImpulseCompletionCounter {
    var count: Int = 0
    var errorCodes: [Int] = []
}

final class ImpulseUnconfiguredRequestServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ImpulseEngineTestLogger.install()
    }


    func testRequestCancelledBeforeCompletionNeverCompletes() {
        let queue: Queue = Queue(name: "impulse.unconfigured.request.cancel")
        let service: ImpulseUnconfiguredRequestService = ImpulseUnconfiguredRequestService(queue: queue)
        let gate: DispatchSemaphore = DispatchSemaphore(value: 0)
        let counter: ImpulseCompletionCounter = ImpulseCompletionCounter()

        queue.async({
            gate.wait()
        })
        let disposable: Disposable = service.add(impulseMakeRequest(completed: { _ in
            counter.count += 1
        }))
        disposable.dispose()
        gate.signal()
        self.flush(queue)

        XCTAssertEqual(counter.count, 0)
    }


    func testRequestCompletesOnceWithNotConfiguredErrorWhenNotCancelled() {
        let queue: Queue = Queue(name: "impulse.unconfigured.request.complete")
        let service: ImpulseUnconfiguredRequestService = ImpulseUnconfiguredRequestService(queue: queue)
        let counter: ImpulseCompletionCounter = ImpulseCompletionCounter()

        let disposable: Disposable = service.add(impulseMakeRequest(completed: { result in
            counter.count += 1
            if case .failure(let failure) = result {
                counter.errorCodes.append(Int(failure.error.errorCode))
            }
        }))
        self.flush(queue)
        disposable.dispose()
        self.flush(queue)

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(counter.errorCodes, [Int(ImpulseUnconfiguredNetworkEngine.notConfiguredError.errorCode)])
    }


    /// Waits until the work queued on `queue` before this call has run.
    private func flush(_ queue: Queue) {
        let done: DispatchSemaphore = DispatchSemaphore(value: 0)
        queue.async({
            done.signal()
        })
        let _ = done.wait(timeout: .now() + 5.0)
    }
}
