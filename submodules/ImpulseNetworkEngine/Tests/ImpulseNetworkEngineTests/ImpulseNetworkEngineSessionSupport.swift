import Foundation
import ImpulseTransport
import MtProtoKit
import SwiftSignalKit
@testable import TelegramCore
@testable import ImpulseNetworkEngine


/// The layer 232 mapping the transcoder reads, loaded once for the session tests.
let impulseSessionTestMapping: ImpulseMapping = {
    do {
        return try ImpulseMapping.loadBundled()
    } catch {
        fatalError("the bundled mapping does not load: \(error)")
    }
}()


/// The TL bytes of `auth.resetAuthorizations`: a call without parameters and with a Bool result.
let impulseSessionTestPayload: [UInt8] = {
    guard let method: ImpulseMappingMethod = impulseSessionTestMapping.method(name: "auth.resetAuthorizations") else {
        fatalError("the mapping has no auth.resetAuthorizations")
    }
    return withUnsafeBytes(of: method.id.littleEndian, { (buffer: UnsafeRawBufferPointer) -> [UInt8] in
        return Array(buffer)
    })
}()


/// The protobuf reply of a Bool result that is `true`.
let impulseSessionTestReply: [UInt8] = [0x08, 0x01]

/// The SDK code of a call that the carrier cancelled.
let impulseSessionTestCancelled: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:])


/// A carrier failure the server answered with `appCode` and the error text `appType`.
func impulseServerFailure(appCode: Int, appType: String) -> ImpulseCarrierFailure {
    return ImpulseCarrierFailure(sdkCode: 0, appCode: appCode, appType: appType, metadata: [:])
}


struct ImpulseTestTokens: ImpulseRequestSession {
    func hasSession() async -> Bool {
        return true
    }


    func needsProactiveRefresh() async -> Bool {
        return false
    }


    func refresh() async throws -> ImpulseRefreshOutcome {
        return .refreshed
    }
}


/// One answer of a scripted carrier: what the send returns, and how long it takes first.
struct ImpulseScriptedStep {
    let result: Result<[UInt8], ImpulseCarrierFailure>
    let delaySeconds: Double
}


/// Answers the sends in order with the scripted steps. Once the script runs out a send waits a minute, so the call stays
/// open until it is cancelled.
final class ImpulseScriptedCarrier: ImpulseRequestCarrier, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let steps: [ImpulseScriptedStep]
    private var sends: Int = 0


    init(steps: [ImpulseScriptedStep]) {
        self.steps = steps
    }


    func send(
        method: String,
        data: [UInt8],
        timeoutSeconds: TimeInterval
    ) async -> Result<[UInt8], ImpulseCarrierFailure> {
        let step: ImpulseScriptedStep = self.nextStep()
        if step.delaySeconds > 0.0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(step.delaySeconds * 1_000_000_000.0))
            } catch {
                return .failure(impulseSessionTestCancelled)
            }
        }
        return step.result
    }


    func sendCount() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sends
    }


    private func nextStep() -> ImpulseScriptedStep {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        let index: Int = self.sends
        self.sends += 1
        if index < self.steps.count {
            return self.steps[index]
        }
        return ImpulseScriptedStep(result: .failure(impulseSessionTestCancelled), delaySeconds: 60.0)
    }
}


/// Records what the tests observe, in order, from any thread.
final class ImpulseTestLog: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var entries: [String] = []


    func append(_ entry: String) {
        self.lock.lock()
        self.entries.append(entry)
        self.lock.unlock()
    }


    func contents() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.entries
    }


    func count(of entry: String) -> Int {
        return self.contents().filter({ (candidate: String) -> Bool in
            return candidate == entry
        }).count
    }
}


final class ImpulseRecordingDelegate: NetworkEngineSessionDelegate {
    private let log: ImpulseTestLog


    init(log: ImpulseTestLog) {
        self.log = log
    }


    func networkSessionAuthorizationRequired() {
        self.log.append("authorization")
    }


    func networkSessionSoftAuthReset() {
        self.log.append("soft-reset")
    }


    func networkSessionConnectionStateChanged(_ state: NetworkEngineConnectionState) {
    }
}


final class ImpulseRecordingControl: ImpulseNetworkTransportControl {
    private let log: ImpulseTestLog


    init(log: ImpulseTestLog) {
        self.log = log
    }


    func setPaused(_ paused: Bool) {
        self.log.append("paused:\(paused)")
    }


    func setOnline(_ online: Bool) {
        self.log.append("online:\(online)")
    }
}


final class ImpulseRecordingUpdateSink: NetworkEngineUpdateSink {
    private let log: ImpulseTestLog


    init(log: ImpulseTestLog) {
        self.log = log
    }


    func networkSessionDidReset() {
        self.log.append("reset")
    }


    func networkSessionDidReceive(message: Any) {
        self.log.append("message:\(message)")
    }
}


/// A request service that keeps what it is given and never runs it.
final class ImpulseRecordingRequestService: NetworkEngineRequestService {
    private let lock: NSLock = NSLock()
    private var requests: [NetworkEngineRequest] = []


    func add(_ request: NetworkEngineRequest) -> Disposable {
        self.lock.lock()
        self.requests.append(request)
        self.lock.unlock()
        return ActionDisposable(action: {
        })
    }


    func names() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.requests.map({ (request: NetworkEngineRequest) -> String in
            return request.shortMetadata.description
        })
    }
}


/// The session of the tests: a transport session on the scripted carrier, the request timing of the tests, and a bridge
/// that parses every update to the text "update".
func impulseMakeEngineSession(
    role: NetworkEngineSessionRole = .main,
    carrier: ImpulseScriptedCarrier,
    delegate: NetworkEngineSessionDelegate? = nil,
    timing: ImpulseNetworkRetryTiming = ImpulseNetworkRetryTiming(serverErrorDelay: 0.0, parseFailureDelay: 0.0),
    control: ImpulseNetworkTransportControl? = nil,
    updateBridge: ImpulseUpdateBridge = ImpulseUpdateBridge(
        parse: { (data: Data) -> Any? in
            return "update"
        },
        knownDatacenterIds: { () -> Set<Int32> in
            return []
        },
        applyDcOptions: { (options: [ImpulseDcUpdateOption]) -> Void in
        }
    ),
    onParseFailure: @escaping () -> Void = {
    }
) -> ImpulseNetworkEngineSession {
    let transportRole: ImpulseSessionRole
    switch role {
    case .main:
        transportRole = .main

    case .worker(let masterDatacenterId, let isMedia, let isCdn):
        transportRole = .worker(masterDatacenterId: masterDatacenterId, isMedia: isMedia, isCdn: isCdn)
    }
    return ImpulseNetworkEngineSession(
        datacenterId: 4,
        role: role,
        delegate: delegate,
        updateBridge: updateBridge,
        timing: timing,
        control: control,
        onParseFailure: onParseFailure,
        makeTransport: { (events: ImpulseNetworkSessionEvents) -> ImpulseNetworkSession in
            return ImpulseNetworkSession(
                datacenterId: 4,
                role: transportRole,
                transcoder: ImpulseTranscoder(mapping: impulseSessionTestMapping),
                session: ImpulseTestTokens(),
                updateCarrier: carrier,
                mediaCarrier: carrier,
                poolCarrier: carrier,
                declarations: nil,
                signedIn: true,
                delegate: events,
                clock: ImpulseSystemRequestClock()
            )
        }
    )
}


/// A request of the tests: the `auth.resetAuthorizations` payload, named `name`, parsed by `parse`.
func impulseMakeRequest(
    name: String = "impulse.request",
    parse: @escaping (Data) -> Any? = { (data: Data) -> Any? in
        return "parsed"
    },
    shouldContinueAfterError: @escaping (NetworkEngineErrorContext) -> Bool = { (context: NetworkEngineErrorContext) -> Bool in
        return false
    },
    dependsOn: ((WrappedRequestMetadata) -> Bool)? = nil,
    acknowledged: (() -> Void)? = nil,
    completed: @escaping (Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void
) -> NetworkEngineRequest {
    return NetworkEngineRequest(
        payload: Data(impulseSessionTestPayload),
        metadata: WrappedRequestMetadata(metadata: name, tag: nil),
        shortMetadata: WrappedRequestShortMetadata(shortMetadata: name),
        parse: parse,
        options: NetworkEngineRequestOptions(),
        shouldContinueAfterError: shouldContinueAfterError,
        dependsOn: dependsOn,
        acknowledged: acknowledged,
        progress: nil,
        completed: completed
    )
}
