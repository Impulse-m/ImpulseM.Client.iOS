import XCTest
import SwiftSignalKit
import MtProtoKit
import TelegramCore
@testable import ImpulseNetworkEngine

final class ImpulseEngineBehaviourTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ImpulseEngineTestLogger.install()
    }


    func testKindIsImpulse() {
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: impulseMakeContext(), sessionBuilder: { datacenterId, _, _, _ in
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        XCTAssertEqual(engine.kind, .impulse)
    }

    func testMakeSessionUsesInjectedBuilder() {
        let recorder: ImpulseSessionRecorder = ImpulseSessionRecorder()
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: impulseMakeContext(), sessionBuilder: { datacenterId, role, _, delegate in
            recorder.record(datacenterId: datacenterId, role: role, delegate: delegate)
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        let delegate: ImpulseFakeSessionDelegate = ImpulseFakeSessionDelegate()
        let role: NetworkEngineSessionRole = .worker(masterDatacenterId: 2, isMedia: true, isCdn: false)
        let session: NetworkEngineSession = engine.makeSession(datacenterId: 4, role: role, usageCalculationInfo: nil, delegate: delegate)
        XCTAssertEqual(session.datacenterId, 4)
        XCTAssertEqual(recorder.datacenterIds, [4])
        XCTAssertEqual(recorder.roles, [role])
        XCTAssertTrue(recorder.lastDelegate === delegate)
    }

    func testActivateInstallsNoNetworkFactoriesAndDeactivateRestoresThem() {
        let context: MTContext = impulseMakeContext()
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: context, sessionBuilder: { datacenterId, _, _, _ in
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        engine.activate()
        impulseFlushContextQueue()
        XCTAssertNotNil(context.authActionFactory)
        XCTAssertNotNil(context.transferAuthActionFactory)
        engine.deactivate()
        impulseFlushContextQueue()
        XCTAssertNil(context.authActionFactory)
        XCTAssertNil(context.transferAuthActionFactory)
    }

    func testNoNetworkAuthActionFailsWithoutRequest() {
        let context: MTContext = impulseMakeContext()
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: context, sessionBuilder: { datacenterId, _, _, _ in
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        engine.activate()
        impulseFlushContextQueue()
        guard let factory = context.authActionFactory else {
            XCTFail("the engine did not install the key action factory")
            return
        }
        var completedAction: MTDatacenterAuthAction?
        var succeeded: Bool?
        let action: MTDatacenterAuthAction = factory(.persistent, false, false, { completed, success in
            completedAction = completed
            succeeded = success
        })
        XCTAssertTrue(action is ImpulseNoNetworkAuthAction)
        action.execute(context, datacenterId: 2)
        XCTAssertEqual(succeeded, false)
        XCTAssertTrue(completedAction === action)
        engine.deactivate()
        impulseFlushContextQueue()
    }

    func testNoNetworkTransferActionFailsWithoutRequest() {
        let context: MTContext = impulseMakeContext()
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: context, sessionBuilder: { datacenterId, _, _, _ in
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        engine.activate()
        impulseFlushContextQueue()
        guard let factory = context.transferAuthActionFactory else {
            XCTFail("the engine did not install the transfer action factory")
            return
        }
        let action: MTDatacenterTransferAuthAction = factory()
        XCTAssertTrue(action is ImpulseNoNetworkTransferAction)
        let delegate: ImpulseRecordingTransferDelegate = ImpulseRecordingTransferDelegate()
        action.delegate = delegate
        action.execute(context, masterDatacenterId: 1, destinationDatacenterId: 2, authToken: "token")
        XCTAssertTrue(delegate.failed)
        XCTAssertFalse(delegate.completed)
        engine.deactivate()
        impulseFlushContextQueue()
    }

    func testNetworkIdentityHasNoAddress() throws {
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(context: impulseMakeContext(), sessionBuilder: { datacenterId, _, _, _ in
            return ImpulseFakeNetworkSession(datacenterId: datacenterId)
        })
        guard let identity: String = engine.networkIdentity() else {
            throw XCTSkip("the machine has no active network interface")
        }
        XCTAssertEqual(identity.count, 32)
        XCTAssertFalse(identity.contains("."))
        XCTAssertFalse(identity.contains(":"))
        XCTAssertEqual(engine.networkIdentity(), identity)
    }
}
