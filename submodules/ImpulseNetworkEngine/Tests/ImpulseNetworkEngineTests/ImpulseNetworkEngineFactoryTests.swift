import XCTest
import MtProtoKit
import SwiftCentrifuge
import SwiftSignalKit
import TelegramCore
@testable import ImpulseTransport
@testable import ImpulseNetworkEngine

final class ImpulseNetworkEngineFactoryTests: XCTestCase {
    private let testGroup: String = "test.group"
    private let testBaseUrl: String = "https://rpc.example.org"

    override func setUp() {
        super.setUp()
        ImpulseEngineTestLogger.install()
    }


    func testFactoryNeverReturnsNilForTheMainApplication() {
        let factory: ImpulseNetworkEngineFactory = self.makeFactory()
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: false)
        XCTAssertNotNil(engine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testFactoryNeverReturnsNilForAnAppExtension() {
        let factory: ImpulseNetworkEngineFactory = self.makeFactory()
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: true)
        XCTAssertNotNil(engine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testFactoryDoesNotSupportWebProxy() {
        XCTAssertFalse(self.makeFactory().supportsWebProxy)
    }

    func testFactoryWithNilBaseUrlGivesTheUnconfiguredEngine() {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(baseUrl: nil)
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: false)
        XCTAssertTrue(engine is ImpulseUnconfiguredNetworkEngine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testFactoryWithEmptyBaseUrlGivesTheUnconfiguredEngine() {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(baseUrl: "")
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: true)
        XCTAssertTrue(engine is ImpulseUnconfiguredNetworkEngine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testFactoryWithInvalidBaseUrlGivesTheUnconfiguredEngine() {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(baseUrl: "rpc.example.org")
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: false)
        XCTAssertTrue(engine is ImpulseUnconfiguredNetworkEngine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testUnconfiguredEngineFailsEveryRequestWithoutNetwork() {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(baseUrl: nil)
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: false)
        let session: NetworkEngineSession? = engine?.makeSession(datacenterId: 2, role: .main, usageCalculationInfo: nil, delegate: nil)
        let completed: XCTestExpectation = self.expectation(description: "The request fails")
        var failure: NetworkEngineRequestFailure?
        let request: NetworkEngineRequest = NetworkEngineRequest(
            payload: Data(),
            name: "test.unconfigured",
            parse: { (_: Data) -> Any? in
                return nil
            },
            shouldContinueAfterError: { (_: NetworkEngineErrorContext) -> Bool in
                return false
            },
            completed: { (result: Result<NetworkEngineResponse, NetworkEngineRequestFailure>) -> Void in
                if case .failure(let value) = result {
                    failure = value
                }
                completed.fulfill()
            }
        )
        let _ = session?.requestService.add(request)
        self.wait(for: [completed], timeout: 5.0)
        XCTAssertEqual(failure?.error.errorCode, 500)
        XCTAssertEqual(failure?.error.errorDescription, "IMPULSE_NOT_CONFIGURED")
        XCTAssertEqual(failure?.error.errorDescription, ImpulseUnconfiguredNetworkEngine.notConfiguredError.errorDescription)
    }

    func testFactoryWithoutRouteSourceGivesNoRouteToTheRoot() throws {
        let factory: ImpulseNetworkEngineFactory = self.makeFactory()
        let inputs: ImpulseNetworkCompositionInputs = try factory.makeCompositionInputs(context: impulseMakeContext())
        XCTAssertNil(inputs.routeSource)
    }

    func testPublicFactoryDefaultsToNoRouteSource() throws {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(baseUrl: self.testBaseUrl)
        let inputs: ImpulseNetworkCompositionInputs = try factory.makeCompositionInputs(context: impulseMakeContext())
        XCTAssertNil(inputs.routeSource)
    }

    func testFactoryPassesItsRouteSourceToTheRootInputs() throws {
        let source: ImpulseFactoryRouteSource = ImpulseFactoryRouteSource(currentRoute: ImpulseProxyRoute(
            host: "127.0.0.1",
            port: 1080,
            username: nil,
            password: nil
        ))
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(
            keychain: ImpulseFactoryKeychain(),
            keychainAccessGroup: self.testGroup,
            baseUrl: self.testBaseUrl,
            proxyRouteSource: source
        )
        let inputs: ImpulseNetworkCompositionInputs = try factory.makeCompositionInputs(context: impulseMakeContext())
        XCTAssertTrue(inputs.routeSource === source)
    }

    func testFactoryWithRouteSourceStillNeverReturnsNil() {
        let factory: ImpulseNetworkEngineFactory = ImpulseNetworkEngineFactory(
            keychain: ImpulseFactoryKeychain(),
            keychainAccessGroup: self.testGroup,
            baseUrl: self.testBaseUrl,
            proxyRouteSource: ImpulseFactoryRouteSource(currentRoute: nil)
        )
        let engine: NetworkEngine? = factory.makeEngine(context: impulseMakeContext(), isAppExtension: false)
        XCTAssertNotNil(engine)
        XCTAssertEqual(engine?.kind, .impulse)
    }

    func testActivateStartsTheLifecycleAndDeactivateStopsIt() {
        let lifecycle: ImpulseFactoryLifecycle = ImpulseFactoryLifecycle()
        let engine: ImpulseNetworkEngine = ImpulseNetworkEngine(
            context: impulseMakeContext(),
            sessionBuilder: { datacenterId, _, _, _ in
                return ImpulseFakeNetworkSession(datacenterId: datacenterId)
            },
            lifecycle: lifecycle
        )
        engine.activate()
        XCTAssertEqual(lifecycle.events, ["start"])
        engine.deactivate()
        XCTAssertEqual(lifecycle.events, ["start", "stop"])
        impulseFlushContextQueue()
    }

    func testUpdateSocketReconnectsWithOneToThirtySecondBackoffAndPingWatchdog() {
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makeUpdateConfig(tokenGetter: nil)
        XCTAssertEqual(config.minReconnectDelay, 1.0)
        XCTAssertEqual(config.maxReconnectDelay, 30.0)
        XCTAssertEqual(config.maxServerPingDelay, ImpulseSocketPolicy.maxServerPingDelaySeconds)
        XCTAssertEqual(config.timeout, ImpulseRequestTimeouts.updateCallSeconds)
        XCTAssertTrue(config.useNativeWebSocket)
    }

    func testPoolMainClientReconnectsWithOneToThirtySecondBackoffAndPingWatchdog() {
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makePoolConfig()
        XCTAssertEqual(config.minReconnectDelay, 1.0)
        XCTAssertEqual(config.maxReconnectDelay, 30.0)
        XCTAssertEqual(config.maxServerPingDelay, ImpulseSocketPolicy.maxServerPingDelaySeconds)
        XCTAssertEqual(config.timeout, ImpulsePoolCarrier.callTimeoutSeconds)
        XCTAssertEqual(config.name, ImpulsePoolCarrier.clientName)
    }

    func testUpdateSocketWithoutRouteSourceHasNoRouteProvider() {
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makeUpdateConfig(tokenGetter: nil, routeSource: nil)
        XCTAssertNil(config.urlSessionConfigurationProvider)
    }

    func testUpdateSocketWithRouteSourceConnectsThroughTheRoute() {
        let source: ImpulseFactoryRouteSource = ImpulseFactoryRouteSource(currentRoute: ImpulseProxyRoute(
            host: "127.0.0.1",
            port: 1080,
            username: nil,
            password: nil
        ))
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makeUpdateConfig(tokenGetter: nil, routeSource: source)
        XCTAssertNotNil(config.urlSessionConfigurationProvider)
        let configuration: URLSessionConfiguration? = config.urlSessionConfigurationProvider?()
        XCTAssertEqual(configuration?.connectionProxyDictionary?[ImpulseProxyConnectionProxy.httpsProxyKey] as? String, "127.0.0.1")
        XCTAssertEqual(configuration?.connectionProxyDictionary?[ImpulseProxyConnectionProxy.httpsPortKey] as? Int, 1080)
        XCTAssertEqual(config.timeout, ImpulseRequestTimeouts.updateCallSeconds)
    }

    func testPoolMainClientWithoutRouteSourceHasNoRouteProvider() {
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makePoolConfig(routeSource: nil)
        XCTAssertNil(config.urlSessionConfigurationProvider)
    }

    func testPoolMainClientWithRouteSourceConnectsThroughTheRoute() {
        let source: ImpulseFactoryRouteSource = ImpulseFactoryRouteSource(currentRoute: ImpulseProxyRoute(
            host: "127.0.0.1",
            port: 1080,
            username: nil,
            password: nil
        ))
        let config: CentrifugeClientConfig = ImpulseNetworkCompositionRoot.makePoolConfig(routeSource: source)
        XCTAssertNotNil(config.urlSessionConfigurationProvider)
        let configuration: URLSessionConfiguration? = config.urlSessionConfigurationProvider?()
        XCTAssertEqual(configuration?.connectionProxyDictionary?[ImpulseProxyConnectionProxy.httpProxyKey] as? String, "127.0.0.1")
        XCTAssertEqual(config.name, ImpulsePoolCarrier.clientName)
    }

    func testMediaTransportWithRouteSourceIsASocketTransport() {
        let source: ImpulseFactoryRouteSource = ImpulseFactoryRouteSource(currentRoute: ImpulseProxyRoute(
            host: "127.0.0.1",
            port: 1080,
            username: nil,
            password: nil
        ))
        let transport: ImpulseMediaTransport = ImpulseNetworkCompositionRoot.makeMediaTransport(
            endpoint: "wss://media.example.invalid/socket",
            tokenGetter: { (_: CentrifugeConnectionTokenEvent, _: @escaping (Result<String, Error>) -> Void) -> Void in
            },
            routeSource: source
        )
        XCTAssertTrue(transport is ImpulseMediaSocketTransport)
    }

    func testMediaTransportWithoutRouteSourceIsASocketTransport() {
        let transport: ImpulseMediaTransport = ImpulseNetworkCompositionRoot.makeMediaTransport(
            endpoint: "wss://media.example.invalid/socket",
            tokenGetter: { (_: CentrifugeConnectionTokenEvent, _: @escaping (Result<String, Error>) -> Void) -> Void in
            },
            routeSource: nil
        )
        XCTAssertTrue(transport is ImpulseMediaSocketTransport)
    }

    func testMediaConfigWithRouteSourceConnectsThroughTheRouteOnTheNativeSocket() {
        let source: ImpulseFactoryRouteSource = ImpulseFactoryRouteSource(currentRoute: ImpulseProxyRoute(
            host: "127.0.0.1",
            port: 1080,
            username: nil,
            password: nil
        ))
        let config: CentrifugeClientConfig = ImpulseMediaSocketTransport.makeConfig(
            tokenGetter: { (_: CentrifugeConnectionTokenEvent, _: @escaping (Result<String, Error>) -> Void) -> Void in
            },
            routeSource: source
        )
        let configuration: URLSessionConfiguration? = config.urlSessionConfigurationProvider?()
        XCTAssertTrue(config.useNativeWebSocket)
        XCTAssertEqual(configuration?.connectionProxyDictionary?[ImpulseProxyConnectionProxy.httpsProxyKey] as? String, "127.0.0.1")
    }

    func testMediaConfigWithoutRouteSourceHasNoRouteProvider() {
        let config: CentrifugeClientConfig = ImpulseMediaSocketTransport.makeConfig(
            tokenGetter: { (_: CentrifugeConnectionTokenEvent, _: @escaping (Result<String, Error>) -> Void) -> Void in
            },
            routeSource: nil
        )
        XCTAssertTrue(config.useNativeWebSocket)
        XCTAssertNil(config.urlSessionConfigurationProvider)
    }

    func testMainSessionBecomesTheRealtimeReceiverAndWorkerSessionDoesNot() throws {
        let root: ImpulseNetworkCompositionRoot = try self.makeRoot()
        let main: ImpulseNetworkEngineSession? = root.makeSession(datacenterId: 2, role: .main, delegate: nil) as? ImpulseNetworkEngineSession
        XCTAssertEqual(main?.transport.role, ImpulseSessionRole.main)
        XCTAssertTrue(root.forwarder.currentDelivery() === main?.transport)

        let workerRole: NetworkEngineSessionRole = .worker(masterDatacenterId: 2, isMedia: true, isCdn: false)
        let worker: ImpulseNetworkEngineSession? = root.makeSession(datacenterId: 4, role: workerRole, delegate: nil) as? ImpulseNetworkEngineSession
        XCTAssertEqual(worker?.datacenterId, 4)
        XCTAssertEqual(worker?.transport.role, ImpulseSessionRole.worker(masterDatacenterId: 2, isMedia: true, isCdn: false))
        XCTAssertTrue(root.forwarder.currentDelivery() === main?.transport)
    }

    func testRealtimeUpdateReachesTheReceiverWithItsLane() throws {
        let root: ImpulseNetworkCompositionRoot = try self.makeRoot()
        let recorder: ImpulseFactoryDelivery = ImpulseFactoryDelivery()
        root.forwarder.setDelivery(recorder)
        root.forwarder.forward(updates: ImpulseRealtimeUpdates(channel: "system:config", tl: [1, 2, 3, 4]))
        XCTAssertEqual(recorder.updates.count, 1)
        XCTAssertEqual(recorder.updates.first?.channel, "system:config")
        XCTAssertEqual(recorder.updates.first?.tl, [1, 2, 3, 4])
    }

    func testEveryDifferenceRequestResetsTheReceiver() throws {
        let root: ImpulseNetworkCompositionRoot = try self.makeRoot()
        let recorder: ImpulseFactoryDelivery = ImpulseFactoryDelivery()
        root.forwarder.setDelivery(recorder)
        root.forwarder.forward(difference: .account(.publicationDecodeFailed))
        root.forwarder.forward(difference: .channel(channelId: 7, reason: .updatesTooLong))
        XCTAssertEqual(recorder.resets, 2)
        XCTAssertTrue(recorder.updates.isEmpty)
    }

    func testUpdateWithoutMainSessionIsDropped() throws {
        let root: ImpulseNetworkCompositionRoot = try self.makeRoot()
        root.forwarder.forward(updates: ImpulseRealtimeUpdates(channel: "user:1", tl: [9]))
        root.forwarder.forward(difference: .account(.updatesTooLong))
        XCTAssertNil(root.forwarder.currentDelivery())
    }

    private func makeFactory() -> ImpulseNetworkEngineFactory {
        return ImpulseNetworkEngineFactory(
            keychain: ImpulseFactoryKeychain(),
            keychainAccessGroup: self.testGroup,
            baseUrl: self.testBaseUrl
        )
    }

    private func makeRoot() throws -> ImpulseNetworkCompositionRoot {
        let inputs: ImpulseNetworkCompositionInputs = ImpulseNetworkCompositionInputs(
            endpoints: try ImpulseEndpoints(baseUrl: self.testBaseUrl),
            mapping: try ImpulseMapping.loadBundled(),
            keychain: ImpulseFactoryKeychain(),
            keychainAccessGroup: self.testGroup,
            identityClock: ImpulseFactoryClock(),
            identityScheduler: ImpulseFactoryScheduler(),
            declaration: ImpulseNetworkEngineFactory.makeDeclaration(environment: impulseMakeContext().apiEnvironment),
            updateBridge: ImpulseUpdateBridge(context: impulseMakeContext()),
            routeSource: nil
        )
        return try ImpulseNetworkCompositionRoot(inputs: inputs)
    }
}


/// An in-memory keychain: the items live as long as the double.
final class ImpulseFactoryKeychain: ImpulseKeychain, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var items: [String: Data] = [:]


    init() {
    }


    func readData(
        service: String,
        account: String,
        accessGroup: String?
    ) -> Data? {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.items[ImpulseFactoryKeychain.key(service: service, account: account, accessGroup: accessGroup)]
    }


    func writeData(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) {
        self.lock.lock()
        self.items[ImpulseFactoryKeychain.key(service: service, account: account, accessGroup: accessGroup)] = data
        self.lock.unlock()
    }


    func deleteData(
        service: String,
        account: String,
        accessGroup: String?
    ) {
        self.lock.lock()
        self.items.removeValue(forKey: ImpulseFactoryKeychain.key(service: service, account: account, accessGroup: accessGroup))
        self.lock.unlock()
    }


    private static func key(
        service: String,
        account: String,
        accessGroup: String?
    ) -> String {
        return service + "/" + account + "/" + (accessGroup ?? "<own items>")
    }
}


struct ImpulseFactoryClock: ImpulseIdentityClock {
    func nowUnixSeconds() -> Double {
        return 0
    }
}


/// A scheduler that never waits: a renewal that sleeps ends at once, with the cancellation it would get.
struct ImpulseFactoryScheduler: ImpulseIdentityScheduler {
    func sleep(seconds: Double) async throws {
        throw CancellationError()
    }
}


final class ImpulseFactoryLifecycle: ImpulseNetworkLifecycle {
    private(set) var events: [String] = []


    func start() {
        self.events.append("start")
    }


    func stop() {
        self.events.append("stop")
    }
}


/// A route source with a fixed route. It never delivers an epoch, since the composition inputs only carry it.
final class ImpulseFactoryRouteSource: ImpulseProxyRouteSource {
    let currentRoute: ImpulseProxyRoute?


    init(currentRoute: ImpulseProxyRoute?) {
        self.currentRoute = currentRoute
    }


    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation {
        return ImpulseFactoryRouteObservation()
    }
}


final class ImpulseFactoryRouteObservation: ImpulseProxyRouteObservation {
    func cancel() {
    }
}


final class ImpulseFactoryDelivery: ImpulseUpdateDelivering {
    private(set) var updates: [(tl: [UInt8], channel: String)] = []
    private(set) var resets: Int = 0


    func deliverUpdate(
        tl: [UInt8],
        channel: String
    ) {
        self.updates.append((tl: tl, channel: channel))
    }


    func deliverReset() {
        self.resets += 1
    }
}
