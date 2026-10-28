import Foundation
import SwiftSignalKit
import MtProtoKit
import EncryptionProvider
@testable import TelegramCore
@testable import ImpulseNetworkEngine

final class ImpulseUnusedEncryptionProvider: NSObject, EncryptionProvider {
    func createBignumContext() -> MTBignumContext {
        preconditionFailure("the tests never reach MtProtoKit cryptography")
    }

    func rsaEncrypt(withPublicKey publicKey: String, data: Data) -> Data? {
        return nil
    }

    func rsaEncryptPKCS1OAEP(withPublicKey publicKey: String, data: Data) -> Data? {
        return nil
    }

    func parseRSAPublicKey(_ publicKey: String) -> MTRsaPublicKey {
        preconditionFailure("the tests never reach MtProtoKit cryptography")
    }

    func macosRSAEncrypt(_ publicKey: String, data: Data) -> Data {
        return Data()
    }
}

func impulseMakeContext() -> MTContext {
    var apiEnvironment: MTApiEnvironment = MTApiEnvironment(deviceModelName: "ImpulseNetworkEngine tests")
    apiEnvironment.apiId = 9
    return MTContext(
        serialization: Serialization(),
        encryptionProvider: ImpulseUnusedEncryptionProvider(),
        apiEnvironment: apiEnvironment,
        isTestingEnvironment: true,
        useTempAuthKeys: true
    )
}

/// Waits until the work queued on MTContext's queue before this call has run.
func impulseFlushContextQueue() {
    let done: DispatchSemaphore = DispatchSemaphore(value: 0)
    MTContext.contextQueue().dispatch(onQueue: {
        done.signal()
    }, synchronous: false)
    let _ = done.wait(timeout: .now() + 5.0)
}

/// Logger shared by every engine test. Logger.shared asserts when no shared logger is set, so each test class installs this one in setUp.
enum ImpulseEngineTestLogger {
    static let logger: Logger = {
        let path: String = NSTemporaryDirectory() + "impulse-network-engine-tests-\(getpid())"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let logger: Logger = Logger(rootPath: path, basePath: path)
        logger.logToFile = false
        logger.logToConsole = false
        return logger
    }()

    static func install() {
        Logger.setSharedLogger(ImpulseEngineTestLogger.logger)
    }
}

final class ImpulseFakeRequestService: NetworkEngineRequestService {
    func add(_ request: NetworkEngineRequest) -> Disposable {
        return ActionDisposable(action: {
        })
    }
}

final class ImpulseFakeNetworkSession: NetworkEngineSession {
    let datacenterId: Int
    let requestService: NetworkEngineRequestService = ImpulseFakeRequestService()

    init(datacenterId: Int) {
        self.datacenterId = datacenterId
    }

    func setPaused(_ paused: Bool) {
    }

    func setOnline(_ online: Bool) {
    }

    func addUpdateSink(_ sink: NetworkEngineUpdateSink) {
    }

    func stop() {
    }

    func movePendingRequests(to service: NetworkEngineRequestService, deadline: Double, completion: @escaping () -> Void) {
        completion()
    }
}

final class ImpulseFakeSessionDelegate: NetworkEngineSessionDelegate {
    func networkSessionAuthorizationRequired() {
    }

    func networkSessionSoftAuthReset() {
    }

    func networkSessionConnectionStateChanged(_ state: NetworkEngineConnectionState) {
    }
}

final class ImpulseSessionRecorder {
    var datacenterIds: [Int] = []
    var roles: [NetworkEngineSessionRole] = []
    var lastDelegate: AnyObject?

    func record(datacenterId: Int, role: NetworkEngineSessionRole, delegate: NetworkEngineSessionDelegate?) {
        self.datacenterIds.append(datacenterId)
        self.roles.append(role)
        self.lastDelegate = delegate
    }
}

final class ImpulseRecordingTransferDelegate: NSObject, MTDatacenterTransferAuthActionDelegate {
    var completed: Bool = false
    var failed: Bool = false

    func datacenterTransferAuthActionCompleted(_ action: MTDatacenterTransferAuthAction) {
        self.completed = true
    }

    func datacenterTransferAuthActionFailed(_ action: MTDatacenterTransferAuthAction) {
        self.failed = true
    }
}
