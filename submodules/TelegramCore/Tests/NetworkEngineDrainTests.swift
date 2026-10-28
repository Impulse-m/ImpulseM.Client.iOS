import XCTest
import SwiftSignalKit
import MtProtoKit
@testable import TelegramCore

private final class DrainRequestService: NetworkEngineRequestService {
    private let lock = NSLock()
    private var added: [NetworkEngineRequest] = []
    private var cancelled: [NetworkEngineRequest] = []

    func add(_ request: NetworkEngineRequest) -> Disposable {
        self.lock.lock()
        self.added.append(request)
        self.lock.unlock()
        return ActionDisposable { [weak self] in
            guard let self = self else {
                return
            }
            self.lock.lock()
            self.cancelled.append(request)
            self.lock.unlock()
        }
    }

    var requests: [NetworkEngineRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.added
    }

    var cancelledRequests: [NetworkEngineRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }
}

private func drainRequest(_ name: String, policy: @escaping (NetworkEngineErrorContext) -> Bool = { _ in false }, completed: @escaping (Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void = { _ in }) -> NetworkEngineRequest {
    return NetworkEngineRequest(payload: Data([1, 2, 3, 4]), name: name, parse: { $0 }, shouldContinueAfterError: policy, completed: completed)
}

/// The rules a session uses to hand its requests over to another one: the release decision and the
/// delayed move of a request.
final class NetworkEngineDrainTests: XCTestCase {
    func testTheReleaseRule() {
        var asked = 0
        let allow: () -> Bool = {
            asked += 1
            return true
        }
        XCTAssertEqual(networkEngineReleaseDecision(mayHaveRun: false, retryAfter: 12.5, allowsServerError: allow), .move(after: 12.5))
        XCTAssertEqual(networkEngineReleaseDecision(mayHaveRun: false, retryAfter: -3.0, allowsServerError: allow), .move(after: 0.0))
        XCTAssertEqual(networkEngineReleaseDecision(mayHaveRun: false, retryAfter: .nan, allowsServerError: allow), .move(after: 0.0))
        XCTAssertEqual(asked, 0, "a request that never ran moves without asking its policy")
        XCTAssertEqual(networkEngineReleaseDecision(mayHaveRun: true, retryAfter: 30.0, allowsServerError: allow), .move(after: 0.0))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(networkEngineReleaseDecision(mayHaveRun: true, retryAfter: 0.0, allowsServerError: { false }), .fail)
        XCTAssertEqual(networkEngineSwitchedError.errorCode, 500)
        XCTAssertEqual(networkEngineSwitchedError.errorDescription, "ENGINE_SWITCHED")
    }

    func testAMoveAfterAWaitCanBeCancelledBeforeItHappens() {
        let target = DrainRequestService()
        let now = drainRequest("now")
        let _ = networkEngineMove(now, to: target, after: 0.0)
        XCTAssertTrue(target.requests.first === now)

        let later = drainRequest("later")
        let cancelled = drainRequest("cancelled")
        let _ = networkEngineMove(later, to: target, after: 0.2)
        let disposable = networkEngineMove(cancelled, to: target, after: 0.2)
        XCTAssertEqual(target.requests.count, 1, "nothing before the wait ends")
        disposable.dispose()
        let done = self.expectation(description: "the wait ended")
        Queue.concurrentDefaultQueue().after(0.5, {
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
        XCTAssertEqual(target.requests.count, 2)
        XCTAssertTrue(target.requests.last === later)
        XCTAssertFalse(target.requests.contains(where: { $0 === cancelled }), "cancelled during its wait, it never arrives")
    }
}
