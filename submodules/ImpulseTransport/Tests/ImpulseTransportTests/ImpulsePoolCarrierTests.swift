import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class FakePoolMain: ImpulsePoolMain {
    var state: CentrifugeClientState = .disconnected
    var connectCount: Int = 0
    var disconnectCount: Int = 0


    func connect() {
        self.connectCount += 1
        self.state = .connecting
    }


    func disconnect() {
        self.disconnectCount += 1
        self.state = .disconnected
    }
}


private final class FakePoolTransport: ImpulsePoolTransport {
    var sendCount: Int = 0
    var lastMethod: String? = nil
    var lastTimeout: TimeInterval? = nil


    func send(
        endpointKey: String,
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        self.sendCount += 1
        self.lastMethod = method
        self.lastTimeout = timeout
        return {}
    }
}


private final class FakeClock {
    var nanos: UInt64 = 1_000_000_000
}


private final class RenewalRecorder {
    var events: [String] = []
    var succeed: Bool = true


    func renew(completion: @escaping (Result<Void, Error>) -> Void) {
        self.events.append("renew")
        if self.succeed {
            completion(.success(()))
        } else {
            completion(.failure(FakeRenewalError.refused))
        }
    }
}


private enum FakeRenewalError: Error {
    case refused
}


private final class MainConfigRecorder {
    var config: CentrifugeClientConfig? = nil
}


private final class FakeRouteObservation: ImpulseProxyRouteObservation {
    func cancel() {
    }
}


private final class FakeRouteSource: ImpulseProxyRouteSource, Sendable {
    let currentRoute: ImpulseProxyRoute? = nil


    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation {
        return FakeRouteObservation()
    }
}


final class ImpulsePoolCarrierTests: XCTestCase {
    func testPoolOptionsNeverPresentToken() {
        let options: CentrifugeRpcPoolOptions = ImpulsePoolCarrier.makePoolOptions(endpoint: "wss://rpc.example.org/ws")
        XCTAssertFalse(options.tokenFrom)
        XCTAssertTrue(options.token.isEmpty)
        XCTAssertNil(options.tokenGetter)
    }


    func testMainConfigNeverPresentsToken() {
        let config: CentrifugeClientConfig = ImpulsePoolCarrier.makeMainConfig()
        XCTAssertTrue(config.token.isEmpty)
        XCTAssertNil(config.tokenGetter)
    }


    func testInjectedMainConfigReachesTheMainClient() throws {
        let recorder: MainConfigRecorder = MainConfigRecorder()
        let injected: CentrifugeClientConfig = CentrifugeClientConfig(
            minReconnectDelay: 1.0,
            maxReconnectDelay: 30.0,
            maxServerPingDelay: 10.0,
            name: "injected-main",
            useNativeWebSocket: true
        )

        _ = try makeRecordingCarrier(mainConfig: injected, recorder: recorder)

        let received: CentrifugeClientConfig = try XCTUnwrap(recorder.config)
        XCTAssertEqual(received.name, "injected-main")
        XCTAssertEqual(received.minReconnectDelay, 1.0)
        XCTAssertEqual(received.maxReconnectDelay, 30.0)
        XCTAssertEqual(received.maxServerPingDelay, 10.0)
        XCTAssertTrue(received.useNativeWebSocket)
    }


    func testMainClientKeepsTheDefaultConfigWhenNoneIsInjected() throws {
        let recorder: MainConfigRecorder = MainConfigRecorder()

        _ = try makeRecordingCarrier(mainConfig: nil, recorder: recorder)

        let received: CentrifugeClientConfig = try XCTUnwrap(recorder.config)
        XCTAssertEqual(received.name, ImpulsePoolCarrier.clientName)
        XCTAssertEqual(received.minReconnectDelay, ImpulseSocketPolicy.minReconnectDelaySeconds)
        XCTAssertEqual(received.maxReconnectDelay, ImpulseSocketPolicy.maxReconnectDelaySeconds)
        XCTAssertEqual(received.maxServerPingDelay, ImpulseSocketPolicy.maxServerPingDelaySeconds)
        XCTAssertTrue(received.useNativeWebSocket)
        XCTAssertTrue(received.token.isEmpty)
    }


    func testMainConfigCarriesTheRouteProviderOnlyWithASource() {
        let routed: CentrifugeClientConfig = ImpulsePoolCarrier.makeMainConfig(routeSource: FakeRouteSource())
        XCTAssertNotNil(routed.urlSessionConfigurationProvider)
        XCTAssertEqual(routed.name, ImpulsePoolCarrier.clientName)
        XCTAssertTrue(routed.useNativeWebSocket)
        let direct: CentrifugeClientConfig = ImpulsePoolCarrier.makeMainConfig()
        XCTAssertNil(direct.urlSessionConfigurationProvider)
    }


    func testPoolFleetShape() {
        let options: CentrifugeRpcPoolOptions = ImpulsePoolCarrier.makePoolOptions(endpoint: "wss://rpc.example.org/ws")
        XCTAssertEqual(options.maxConnectionsPerEndpoint, 1)
        XCTAssertEqual(options.maxInflightPerConnection, 1)
        XCTAssertEqual(options.maxQueued, 64)
        XCTAssertEqual(options.timeout, 30.0)
    }


    func testServedMethodsAreTheIdentityPoolSet() {
        XCTAssertEqual(ImpulsePoolCarrier.servedMethods, ["connectionIdentity", "refreshSession"])
    }


    func testStartConnectsMainOnce() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        XCTAssertEqual(main.connectCount, 1)
        carrier.start()
        XCTAssertEqual(main.connectCount, 1)
        main.state = .connecting
        carrier.runWatchdogTick()
        main.state = .connected
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 1)
    }


    func testWatchdogDoesNothingBeforeStart() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 0)
    }


    func testWatchdogReconnectsDisconnectedMainWhileWanted() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        main.state = .disconnected
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 2)
    }


    func testStopHaltsTheWatchdogWithoutTouchingMain() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        carrier.stop()
        main.state = .disconnected
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 1)
    }


    func testResetMainDisconnectsOnceAndNextTickConnectsAgain() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        XCTAssertEqual(main.connectCount, 1)
        main.state = .connected
        carrier.resetMain()
        XCTAssertEqual(main.disconnectCount, 1)
        XCTAssertEqual(main.state, .disconnected)
        carrier.resetMain()
        XCTAssertEqual(main.disconnectCount, 1)
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 2)
        XCTAssertEqual(main.disconnectCount, 1)
    }


    func testResetMainKeepsThePoolWanted() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        main.state = .connected
        carrier.resetMain()
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 2)
        main.state = .disconnected
        carrier.runWatchdogTick()
        XCTAssertEqual(main.connectCount, 3)
    }


    func testStoppedCarrierNeverReconnectsAfterResetMain() {
        let main: FakePoolMain = FakePoolMain()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: main, transport: FakePoolTransport())
        carrier.start()
        carrier.stop()
        main.state = .connected
        carrier.resetMain()
        XCTAssertEqual(main.disconnectCount, 1)
        carrier.runWatchdogTick()
        carrier.drainQueue()
        XCTAssertEqual(main.connectCount, 1)
    }


    func testSessionEndedRenewsIdentityBeforeConnect() {
        let main: FakePoolMain = FakePoolMain()
        let recorder: RenewalRecorder = RenewalRecorder()
        let carrier: ImpulsePoolCarrier = makeCarrier(
            main: main,
            transport: FakePoolTransport(),
            renewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                recorder.renew(completion: completion)
            }
        )
        carrier.start()
        main.state = .disconnected
        carrier.handleMainDisconnected(code: 1)
        carrier.runWatchdogTick()
        carrier.drainQueue()
        XCTAssertEqual(recorder.events, ["renew"])
        XCTAssertEqual(main.connectCount, 2)
    }


    func testFailedRenewalKeepsMainDisconnectedAndRetriesLater() {
        let main: FakePoolMain = FakePoolMain()
        let recorder: RenewalRecorder = RenewalRecorder()
        recorder.succeed = false
        let clock: FakeClock = FakeClock()
        let carrier: ImpulsePoolCarrier = makeCarrier(
            main: main,
            transport: FakePoolTransport(),
            renewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                recorder.renew(completion: completion)
            },
            clock: { () -> UInt64 in
                return clock.nanos
            }
        )
        carrier.start()
        main.state = .disconnected
        carrier.handleMainDisconnected(code: 1)
        carrier.runWatchdogTick()
        carrier.drainQueue()
        carrier.runWatchdogTick()
        carrier.drainQueue()
        XCTAssertEqual(recorder.events, ["renew"])
        XCTAssertEqual(main.connectCount, 1)
        clock.nanos += 6_000_000_000
        recorder.succeed = true
        carrier.runWatchdogTick()
        carrier.drainQueue()
        XCTAssertEqual(recorder.events, ["renew", "renew"])
        XCTAssertEqual(main.connectCount, 2)
    }


    func testMethodOutsideFleetIsRefusedWithoutSending() {
        let transport: FakePoolTransport = FakePoolTransport()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: FakePoolMain(), transport: transport)
        let expectation: XCTestExpectation = XCTestExpectation(description: "refused")
        var received: ImpulsePoolFailure? = nil
        _ = carrier.call(method: "messages.sendMessage", data: Data(), timeoutSeconds: 5) { (result: Result<Data, ImpulsePoolFailure>) -> Void in
            if case .failure(let failure) = result {
                received = failure
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(transport.sendCount, 0)
        let expected: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 0,
            appCode: 400,
            appType: "CLIENT_IDENTITY_REFUSED",
            metadata: [:]
        )
        XCTAssertEqual(received, ImpulsePoolFailure.carrier(expected))
        XCTAssertEqual(
            ImpulseErrors.rpcError(from: expected, fleet: .update),
            ImpulseRpcError(code: 400, text: "CLIENT_IDENTITY_REFUSED", temporary: false)
        )
    }


    func testServedMethodTimeoutIsCutToPoolTimeout() {
        let transport: FakePoolTransport = FakePoolTransport()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: FakePoolMain(), transport: transport)
        _ = carrier.call(method: "connectionIdentity", data: Data(), timeoutSeconds: 90) { (_: Result<Data, ImpulsePoolFailure>) -> Void in
        }
        XCTAssertEqual(transport.sendCount, 1)
        XCTAssertEqual(transport.lastMethod, "connectionIdentity")
        XCTAssertEqual(transport.lastTimeout, 30.0)
    }


    func testZeroTimeoutMeansPoolTimeout() {
        let transport: FakePoolTransport = FakePoolTransport()
        let carrier: ImpulsePoolCarrier = makeCarrier(main: FakePoolMain(), transport: transport)
        _ = carrier.call(method: "refreshSession", data: Data(), timeoutSeconds: 0) { (_: Result<Data, ImpulsePoolFailure>) -> Void in
        }
        XCTAssertNil(transport.lastTimeout)
    }


    func testFailureMappingOfSessionEvents() {
        XCTAssertEqual(ImpulsePoolCarrier.failure(from: CentrifugeError.clientDisconnected), .mainDisconnected)
        XCTAssertEqual(ImpulsePoolCarrier.failure(from: CentrifugeError.unauthorized), .sessionEnded)
    }


    func testFailureMappingOfReplies() {
        let details: CentrifugeReplyError = CentrifugeReplyError(
            code: 103,
            message: "token refused",
            temporary: false,
            appCode: 401,
            appType: "AUTH_KEY_UNREGISTERED",
            metadata: [:]
        )
        XCTAssertEqual(
            ImpulsePoolCarrier.failure(from: CentrifugeError.replyErrorDetails(details)),
            .carrier(ImpulseCarrierFailure(sdkCode: 103, appCode: 401, appType: "AUTH_KEY_UNREGISTERED", metadata: [:]))
        )
        XCTAssertEqual(
            ImpulsePoolCarrier.failure(from: CentrifugeError.replyError(code: 17, message: "cancelled", temporary: false)),
            .carrier(ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:]))
        )
        XCTAssertEqual(
            ImpulsePoolCarrier.failure(from: CentrifugeError.timeout),
            .carrier(ImpulseCarrierFailure(sdkCode: 0, appCode: 0, appType: "", metadata: [:]))
        )
    }


    func testRealPoolFailsCallsWhileMainIsDisconnected() throws {
        let carrier: ImpulsePoolCarrier = try ImpulsePoolCarrier(
            endpoint: "wss://rpc.example.org/connection/websocket",
            identityRenewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                completion(.success(()))
            }
        )
        let expectation: XCTestExpectation = XCTestExpectation(description: "gated")
        var received: ImpulsePoolFailure? = nil
        _ = carrier.call(method: "connectionIdentity", data: Data(), timeoutSeconds: 5) { (result: Result<Data, ImpulsePoolFailure>) -> Void in
            if case .failure(let failure) = result {
                received = failure
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(received, ImpulsePoolFailure.mainDisconnected)
    }


    private func makeRecordingCarrier(
        mainConfig: CentrifugeClientConfig?,
        recorder: MainConfigRecorder
    ) throws -> ImpulsePoolCarrier {
        return try ImpulsePoolCarrier(
            endpoint: "wss://rpc.example.org/connection/websocket",
            identityRenewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                completion(.success(()))
            },
            mainConfig: mainConfig,
            makeMainClient: { (endpoint: String, config: CentrifugeClientConfig, delegate: ImpulsePoolMainDelegate) throws -> CentrifugeClient in
                recorder.config = config
                return CentrifugeClient(endpoint: endpoint, config: config, delegate: delegate)
            }
        )
    }


    private func makeCarrier(
        main: FakePoolMain,
        transport: FakePoolTransport,
        renewal: @escaping ImpulsePoolIdentityRenewal = { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
            completion(.success(()))
        },
        clock: @escaping () -> UInt64 = { () -> UInt64 in
            return 1_000_000_000
        }
    ) -> ImpulsePoolCarrier {
        return ImpulsePoolCarrier(
            main: main,
            transport: transport,
            identityRenewal: renewal,
            clock: clock,
            tickInterval: nil
        )
    }
}
