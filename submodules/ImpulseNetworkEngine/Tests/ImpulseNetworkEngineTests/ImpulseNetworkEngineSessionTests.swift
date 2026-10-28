import XCTest
import ImpulseTransport
import SwiftSignalKit
import TelegramCore
@testable import ImpulseNetworkEngine


final class ImpulseNetworkEngineSessionTests: XCTestCase {
    /// Sessions the test keeps alive: a session only completes requests while something holds it.
    private var retained: [AnyObject] = []


    private final class ImpulseActivityBox {
        var value: NetworkEngineServerActivity?
    }


    private func makeSession(
        role: NetworkEngineSessionRole = .main,
        steps: [ImpulseScriptedStep],
        carrier: ImpulseScriptedCarrier? = nil,
        delegate: NetworkEngineSessionDelegate? = nil,
        control: ImpulseNetworkTransportControl? = nil,
        updateBridge: ImpulseUpdateBridge? = nil,
        onParseFailure: @escaping () -> Void = {
        }
    ) -> ImpulseNetworkEngineSession {
        let scripted: ImpulseScriptedCarrier = carrier ?? ImpulseScriptedCarrier(steps: steps)
        let session: ImpulseNetworkEngineSession
        if let updateBridge: ImpulseUpdateBridge = updateBridge {
            session = impulseMakeEngineSession(role: role, carrier: scripted, delegate: delegate, control: control, updateBridge: updateBridge, onParseFailure: onParseFailure)
        } else {
            session = impulseMakeEngineSession(role: role, carrier: scripted, delegate: delegate, control: control, onParseFailure: onParseFailure)
        }
        self.retained.append(session)
        self.retained.append(scripted)
        return session
    }


    /// Waits until the session has processed every request it was given before this call.
    private func flush(_ session: ImpulseNetworkEngineSession) {
        let done: XCTestExpectation = XCTestExpectation(description: "flushed")
        session.serverActivity({ (_: NetworkEngineServerActivity?) -> Void in
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
    }


    private func activity(of session: ImpulseNetworkEngineSession) -> NetworkEngineServerActivity? {
        let reported: XCTestExpectation = XCTestExpectation(description: "activity")
        let box: ImpulseActivityBox = ImpulseActivityBox()
        session.serverActivity({ (activity: NetworkEngineServerActivity?) -> Void in
            box.value = activity
            reported.fulfill()
        })
        self.wait(for: [reported], timeout: 5.0)
        return box.value
    }


    // MARK: Request mapping


    func testRequestCompletesWithParsedResult() {
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0)])
        let log: ImpulseTestLog = ImpulseTestLog()
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        _ = session.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            if case .success(let response) = result, let value: String = response.result as? String {
                log.append(value)
            }
            completed.fulfill()
        }))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(log.contents(), ["parsed"])
    }


    func testAcknowledgedFiresOnceEvenWhenTheRequestIsSentAgain() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 500, appType: "INTERNAL")), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        _ = session.add(impulseMakeRequest(
            shouldContinueAfterError: { (context: NetworkEngineErrorContext) -> Bool in
                return true
            },
            acknowledged: {
                log.append("acknowledged")
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                completed.fulfill()
            }
        ))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(carrier.sendCount(), 2)
        XCTAssertEqual(log.count(of: "acknowledged"), 1)
    }


    // MARK: Errors and the request's policy


    func testServerErrorIsResubmittedWhenThePolicyAllowsIt() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 500, appType: "INTERNAL")), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        _ = session.add(impulseMakeRequest(
            shouldContinueAfterError: { (context: NetworkEngineErrorContext) -> Bool in
                log.append("servers:\(context.internalServerErrorCount)")
                return true
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                if case .success = result {
                    log.append("success")
                }
                completed.fulfill()
            }
        ))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(carrier.sendCount(), 2)
        XCTAssertEqual(log.contents(), ["servers:1", "success"])
    }


    func testServerErrorIsDeliveredWhenThePolicyRefusesIt() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 500, appType: "INTERNAL")), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        var code: Int32 = 0
        var text: String = ""
        _ = session.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            if case .failure(let failure) = result {
                code = failure.error.errorCode
                text = failure.error.errorDescription
            }
            completed.fulfill()
        }))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(carrier.sendCount(), 1)
        XCTAssertEqual(code, 500)
        XCTAssertEqual(text, "INTERNAL")
    }


    func testFloodWaitIsResubmittedWithItsContext() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 420, appType: "FLOOD_WAIT_0")), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        _ = session.add(impulseMakeRequest(
            shouldContinueAfterError: { (context: NetworkEngineErrorContext) -> Bool in
                log.append("\(context.floodWaitSeconds)|\(context.floodWaitErrorText ?? "")")
                return true
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                if case .success = result {
                    log.append("success")
                }
                completed.fulfill()
            }
        ))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(carrier.sendCount(), 2)
        XCTAssertEqual(log.contents(), ["0|FLOOD_WAIT_0", "success"])
    }


    func testReplyThatDoesNotParseIsSentAtMostThreeTimes() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let invalidations: ImpulseTestLog = ImpulseTestLog()
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier, onParseFailure: {
            invalidations.append("invalidated")
        })
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        var code: Int32 = 0
        var text: String = ""
        _ = session.add(impulseMakeRequest(
            parse: { (data: Data) -> Any? in
                return nil
            },
            shouldContinueAfterError: { (context: NetworkEngineErrorContext) -> Bool in
                return true
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                if case .failure(let failure) = result {
                    code = failure.error.errorCode
                    text = failure.error.errorDescription
                }
                completed.fulfill()
            }
        ))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(carrier.sendCount(), 3)
        XCTAssertEqual(invalidations.count(of: "invalidated"), 3)
        XCTAssertEqual(code, 500)
        XCTAssertEqual(text, "TL_PARSING_ERROR")
    }


    func testAnswerThatTheServerLostKeepsTheRequestSilent() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 500, appType: "PROTOCOL_ERROR_ANSWER_LOST")), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        _ = session.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            log.append("completed")
        }))
        self.flush(session)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(carrier.sendCount(), 1)
        XCTAssertEqual(log.count(of: "completed"), 0)
    }


    // MARK: Cancellation, lifetime and ordering


    func testCancelledRequestNeverCompletes() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 30.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        let sent: XCTestExpectation = XCTestExpectation(description: "sent")
        let disposable: Disposable = session.add(impulseMakeRequest(
            acknowledged: {
                sent.fulfill()
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                log.append("completed")
            }
        ))
        self.wait(for: [sent], timeout: 5.0)
        disposable.dispose()
        self.flush(session)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(log.count(of: "completed"), 0)
    }


    func testDependentRequestIsSentAfterItsPredecessorSettles() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.2),
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let log: ImpulseTestLog = ImpulseTestLog()
        let completed: XCTestExpectation = XCTestExpectation(description: "second completed")
        _ = session.add(impulseMakeRequest(name: "first", completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            log.append("completed-first")
        }))
        _ = session.add(impulseMakeRequest(
            name: "second",
            dependsOn: { (metadata: WrappedRequestMetadata) -> Bool in
                return metadata.description == "first"
            },
            acknowledged: {
                log.append("sent-second")
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                log.append("completed-second")
                completed.fulfill()
            }
        ))
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(log.contents(), ["completed-first", "sent-second", "completed-second"])
    }


    func testStoppedSessionRefusesRequests() {
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [])
        session.stop()
        let disposable: Disposable = session.requestService.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
        }))
        XCTAssertTrue(disposable === EmptyDisposable)
    }


    func testReleasedSessionRefusesRequests() {
        var session: ImpulseNetworkEngineSession? = impulseMakeEngineSession(carrier: ImpulseScriptedCarrier(steps: []))
        let service: NetworkEngineRequestService? = session?.requestService
        session = nil
        guard let service: NetworkEngineRequestService = service else {
            XCTFail("the session did not keep its request service")
            return
        }
        let disposable: Disposable = service.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
        }))
        XCTAssertTrue(disposable === EmptyDisposable)
    }


    // MARK: Hand-over


    func testUnsentRequestMovesAndSentRequestFailsAtTheDeadline() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 30.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let target: ImpulseRecordingRequestService = ImpulseRecordingRequestService()
        let log: ImpulseTestLog = ImpulseTestLog()
        let sent: XCTestExpectation = XCTestExpectation(description: "first sent")
        let drained: XCTestExpectation = XCTestExpectation(description: "drained")
        _ = session.add(impulseMakeRequest(name: "first", acknowledged: {
            sent.fulfill()
        }, completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            if case .failure(let failure) = result {
                let text: String = failure.error.errorDescription
                log.append("failed:\(text)")
            }
        }))
        self.wait(for: [sent], timeout: 5.0)
        _ = session.add(impulseMakeRequest(name: "second", dependsOn: { (metadata: WrappedRequestMetadata) -> Bool in
            return metadata.description == "first"
        }, completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            log.append("completed-second")
        }))
        session.movePendingRequests(to: target, deadline: 0.2, completion: {
            drained.fulfill()
        })
        self.wait(for: [drained], timeout: 5.0)
        XCTAssertEqual(target.names(), ["second"])
        XCTAssertEqual(log.contents(), ["failed:ENGINE_SWITCHED"])
    }


    func testSentRequestMovesWhenItsPolicyAllowsAServerError() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 30.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let target: ImpulseRecordingRequestService = ImpulseRecordingRequestService()
        let sent: XCTestExpectation = XCTestExpectation(description: "sent")
        let drained: XCTestExpectation = XCTestExpectation(description: "drained")
        _ = session.add(impulseMakeRequest(name: "first", shouldContinueAfterError: { (context: NetworkEngineErrorContext) -> Bool in
            return true
        }, acknowledged: {
            sent.fulfill()
        }, completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
        }))
        self.wait(for: [sent], timeout: 5.0)
        session.movePendingRequests(to: target, deadline: 0.1, completion: {
            drained.fulfill()
        })
        self.wait(for: [drained], timeout: 5.0)
        XCTAssertEqual(target.names(), ["first"])
    }


    // MARK: Pause, online, activity and drops


    func testControlReceivesPauseAndOnlineChanges() {
        let log: ImpulseTestLog = ImpulseTestLog()
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], control: ImpulseRecordingControl(log: log))
        session.setPaused(false)
        session.setOnline(true)
        session.setOnline(true)
        self.flush(session)
        XCTAssertEqual(log.contents(), ["paused:false", "online:true"])
    }


    func testServerActivityFollowsAnswersAndReportedDrops() {
        let carrier: ImpulseScriptedCarrier = ImpulseScriptedCarrier(steps: [
            ImpulseScriptedStep(result: .success(impulseSessionTestReply), delaySeconds: 0.0),
        ])
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [], carrier: carrier)
        let before: NetworkEngineServerActivity? = self.activity(of: session)
        XCTAssertNil(before?.silentFor)
        XCTAssertEqual(before?.connected, false)

        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        _ = session.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            completed.fulfill()
        }))
        self.wait(for: [completed], timeout: 5.0)
        let answered: NetworkEngineServerActivity? = self.activity(of: session)
        XCTAssertNotNil(answered?.silentFor)
        XCTAssertEqual(answered?.connected, true)

        session.reportConnectionDrop(NetworkEngineConnectionDrop(reason: "test", answered: true, age: 1.0))
        let dropped: NetworkEngineServerActivity? = self.activity(of: session)
        XCTAssertEqual(dropped?.connected, false)
    }


    func testReportedDropReachesEveryObserver() {
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [])
        let log: ImpulseTestLog = ImpulseTestLog()
        session.observeConnectionDrops({ (drop: NetworkEngineConnectionDrop) -> Void in
            log.append("drop:\(drop.reason)")
        })
        session.observeConnectionDrops({ (drop: NetworkEngineConnectionDrop) -> Void in
            log.append("second:\(drop.reason)")
        })
        session.reportConnectionDrop(NetworkEngineConnectionDrop(reason: "socket", answered: false, age: 3.0))
        self.flush(session)
        XCTAssertEqual(log.contents(), ["drop:socket", "second:socket"])
    }


    // MARK: Updates and delegate events


    func testUpdatesAndResetsReachTheSinkOfTheMainSessionOnly() {
        let log: ImpulseTestLog = ImpulseTestLog()
        let bridgeLog: ImpulseTestLog = ImpulseTestLog()
        let bridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                bridgeLog.append("parsed")
                return "update"
            },
            knownDatacenterIds: { () -> Set<Int32> in
                return []
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
            }
        )
        let main: ImpulseNetworkEngineSession = self.makeSession(steps: [], updateBridge: bridge)
        main.addUpdateSink(ImpulseRecordingUpdateSink(log: log))
        main.transport.deliverUpdate(tl: [1, 2, 3], channel: "user:5")
        main.transport.deliverReset()
        XCTAssertEqual(log.contents(), ["message:update", "reset"])

        let workerLog: ImpulseTestLog = ImpulseTestLog()
        let workerBridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
            parse: { (data: Data) -> Any? in
                return "update"
            },
            knownDatacenterIds: { () -> Set<Int32> in
                return []
            },
            applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
            }
        )
        let worker: ImpulseNetworkEngineSession = self.makeSession(role: .worker(masterDatacenterId: 2, isMedia: false, isCdn: false), steps: [], updateBridge: workerBridge)
        worker.addUpdateSink(ImpulseRecordingUpdateSink(log: workerLog))
        worker.transport.deliverUpdate(tl: [1, 2, 3], channel: "user:5")
        worker.transport.deliverReset()
        XCTAssertEqual(workerLog.contents(), [])
    }


    func testAuthorizationRequiredReachesTheMainDelegateOnly() {
        let mainLog: ImpulseTestLog = ImpulseTestLog()
        let mainDelegate: ImpulseRecordingDelegate = ImpulseRecordingDelegate(log: mainLog)
        let main: ImpulseNetworkEngineSession = self.makeSession(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 401, appType: "SESSION_REVOKED")), delaySeconds: 0.0),
        ], delegate: mainDelegate)
        let completed: XCTestExpectation = XCTestExpectation(description: "main completed")
        _ = main.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            completed.fulfill()
        }))
        self.wait(for: [completed], timeout: 5.0)
        self.flush(main)
        XCTAssertEqual(mainLog.count(of: "authorization"), 1)

        let workerLog: ImpulseTestLog = ImpulseTestLog()
        let workerDelegate: ImpulseRecordingDelegate = ImpulseRecordingDelegate(log: workerLog)
        let worker: ImpulseNetworkEngineSession = self.makeSession(role: .worker(masterDatacenterId: 2, isMedia: false, isCdn: false), steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 401, appType: "SESSION_REVOKED")), delaySeconds: 0.0),
        ], delegate: workerDelegate)
        let workerCompleted: XCTestExpectation = XCTestExpectation(description: "worker completed")
        _ = worker.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            workerCompleted.fulfill()
        }))
        self.wait(for: [workerCompleted], timeout: 5.0)
        self.flush(worker)
        XCTAssertEqual(workerLog.count(of: "authorization"), 0)
    }


    func testNotAcceptableReplyResetsTheMainSessionAuthorization() {
        let log: ImpulseTestLog = ImpulseTestLog()
        let delegate: ImpulseRecordingDelegate = ImpulseRecordingDelegate(log: log)
        let session: ImpulseNetworkEngineSession = self.makeSession(steps: [
            ImpulseScriptedStep(result: .failure(impulseServerFailure(appCode: 406, appType: "NOT_ACCEPTABLE")), delaySeconds: 0.0),
        ], delegate: delegate)
        let completed: XCTestExpectation = XCTestExpectation(description: "completed")
        var code: Int32 = 0
        _ = session.add(impulseMakeRequest(completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
            if case .failure(let failure) = result {
                code = failure.error.errorCode
            }
            completed.fulfill()
        }))
        self.wait(for: [completed], timeout: 5.0)
        self.flush(session)
        XCTAssertEqual(code, 406)
        XCTAssertEqual(log.count(of: "soft-reset"), 1)
    }


    func testCanonicalRetryTimingWaitsTwoSecondsBetweenAttempts() {
        XCTAssertEqual(ImpulseNetworkRetryTiming.canonical.serverErrorDelay, 2.0)
        XCTAssertEqual(ImpulseNetworkRetryTiming.canonical.parseFailureDelay, 2.0)
    }
}
