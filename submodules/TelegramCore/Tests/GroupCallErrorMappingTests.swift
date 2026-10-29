import XCTest
import SwiftSignalKit
import MtProtoKit
@testable import TelegramCore

final class GroupCallErrorMappingTests: XCTestCase {
    func testGroupCallInvalidMapsToInvalid() {
        let result: CheckGroupCallError = GroupCallRpcErrorMapping.checkError(errorCode: 400, errorDescription: "GROUPCALL_INVALID")

        XCTAssertEqual(result, .invalid)
    }

    func testOtherBadRequestMapsToBadRequest() {
        let result: CheckGroupCallError = GroupCallRpcErrorMapping.checkError(errorCode: 400, errorDescription: "CHAT_ADMIN_REQUIRED")

        XCTAssertEqual(result, .badRequest)
    }

    func testOtherErrorsMapToGeneric() {
        XCTAssertEqual(GroupCallRpcErrorMapping.checkError(errorCode: 500, errorDescription: "INTERNAL"), .generic)
        XCTAssertEqual(GroupCallRpcErrorMapping.checkError(errorCode: 420, errorDescription: "FLOOD_WAIT_5"), .generic)
    }

    func testSsrcDuplicateMuchIsRecognised() {
        XCTAssertTrue(GroupCallRpcErrorMapping.isSsrcDuplicateMuch(errorDescription: "GROUPCALL_SSRC_DUPLICATE_MUCH"))
        XCTAssertFalse(GroupCallRpcErrorMapping.isSsrcDuplicateMuch(errorDescription: "GROUPCALL_INVALID"))
    }

    func testCheckResultDeliversSourcesAsUnsigned() {
        let source: Signal<[Int32], MTRpcError> = Signal<[Int32], MTRpcError>.single([-1, 5])
        var received: [[UInt32]] = []

        let disposable: Disposable = GroupCallRpcErrorMapping.mapCheckResult(source).start(next: { value in
            received.append(value)
        })
        disposable.dispose()

        XCTAssertEqual(received, [[4294967295, 5]])
    }

    func testCheckResultForwardsInvalidFailure() {
        let source: Signal<[Int32], MTRpcError> = Signal<[Int32], MTRpcError>.fail(MTRpcError(errorCode: 400, errorDescription: "GROUPCALL_INVALID"))
        var receivedError: CheckGroupCallError?

        let disposable: Disposable = GroupCallRpcErrorMapping.mapCheckResult(source).start(error: { error in
            receivedError = error
        })
        disposable.dispose()

        XCTAssertEqual(receivedError, .invalid)
    }

    func testCancelledCheckNeverCompletes() {
        var storedSubscriber: Subscriber<[Int32], MTRpcError>?
        var sourceDisposed: Bool = false
        let source: Signal<[Int32], MTRpcError> = Signal<[Int32], MTRpcError> { subscriber in
            storedSubscriber = subscriber
            return ActionDisposable(action: {
                sourceDisposed = true
            })
        }
        var receivedValue: Bool = false
        var receivedError: Bool = false
        var completed: Bool = false

        let disposable: Disposable = GroupCallRpcErrorMapping.mapCheckResult(source).start(next: { _ in
            receivedValue = true
        }, error: { _ in
            receivedError = true
        }, completed: {
            completed = true
        })
        disposable.dispose()
        storedSubscriber?.putNext([1])
        storedSubscriber?.putCompletion()

        XCTAssertTrue(sourceDisposed)
        XCTAssertFalse(receivedValue)
        XCTAssertFalse(receivedError)
        XCTAssertFalse(completed)
    }
}
