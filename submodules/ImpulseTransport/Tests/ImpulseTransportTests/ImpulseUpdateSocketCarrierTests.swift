import XCTest
import SwiftCentrifuge
@testable import ImpulseTransport


private final class UpdateTransportDouble: ImpulseUpdateTransport {
    private let lock: NSLock = NSLock()
    private let immediate: Result<Data, Error>?
    private let completeTwice: Bool
    private var sentMethods: [String] = []
    private var sentTimeouts: [TimeInterval?] = []
    private var sentPayloads: [Data] = []
    private var cancelCalls: Int = 0


    init(
        immediate: Result<Data, Error>?,
        completeTwice: Bool = false
    ) {
        self.immediate = immediate
        self.completeTwice = completeTwice
    }


    func send(
        method: String,
        data: Data,
        timeout: TimeInterval?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) -> () -> Void {
        self.recordSend(method: method, data: data, timeout: timeout)
        if let result: Result<Data, Error> = self.immediate {
            completion(result)
            if self.completeTwice {
                completion(result)
            }
        }
        return { [weak self] () -> Void in
            self?.recordCancel()
            completion(.failure(CentrifugeError.replyError(code: 17, message: "cancelled", temporary: false)))
        }
    }


    func methods() -> [String] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentMethods
    }


    func timeouts() -> [TimeInterval?] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentTimeouts
    }


    func payloads() -> [Data] {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.sentPayloads
    }


    func cancels() -> Int {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.cancelCalls
    }


    private func recordSend(
        method: String,
        data: Data,
        timeout: TimeInterval?
    ) {
        self.lock.lock()
        self.sentMethods.append(method)
        self.sentPayloads.append(data)
        self.sentTimeouts.append(timeout)
        self.lock.unlock()
    }


    private func recordCancel() {
        self.lock.lock()
        self.cancelCalls += 1
        self.lock.unlock()
    }
}


private final class UpdateRouteObservationNoop: ImpulseProxyRouteObservation {
    func cancel() {
    }
}


private final class UpdateRouteSourceDouble: ImpulseProxyRouteSource, @unchecked Sendable {
    private let route: ImpulseProxyRoute?


    init(route: ImpulseProxyRoute?) {
        self.route = route
    }


    var currentRoute: ImpulseProxyRoute? {
        return self.route
    }


    func observe(_ handler: @escaping @Sendable (Int) -> Void) -> ImpulseProxyRouteObservation {
        return UpdateRouteObservationNoop()
    }
}


final class ImpulseUpdateSocketCarrierTests: XCTestCase {
    func testSendsTheMethodAndTheBytesAndCapsTheDeadline() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(immediate: .success(Data([1, 2, 3])))
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "messages.getHistory",
            data: [9, 8],
            timeoutSeconds: 60
        )

        XCTAssertEqual(result, .success([1, 2, 3]))
        XCTAssertEqual(transport.methods(), ["messages.getHistory"])
        XCTAssertEqual(transport.payloads(), [Data([9, 8])])
        let expectedTimeouts: [TimeInterval?] = [ImpulseRequestTimeouts.updateCallSeconds]
        XCTAssertEqual(transport.timeouts(), expectedTimeouts)
    }


    func testRequestedDeadlineBelowTheCapIsKept() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(immediate: .success(Data()))
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        _ = await carrier.send(method: "users.getFullUser", data: [], timeoutSeconds: 5)

        let expectedTimeouts: [TimeInterval?] = [5]
        XCTAssertEqual(transport.timeouts(), expectedTimeouts)
    }


    func testZeroDeadlineMeansTheClientTimeout() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(immediate: .success(Data()))
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        _ = await carrier.send(method: "users.getFullUser", data: [], timeoutSeconds: 0)

        let expectedTimeouts: [TimeInterval?] = [nil]
        XCTAssertEqual(transport.timeouts(), expectedTimeouts)
    }


    func testServerReplyKeepsItsCodesAndMetadata() async {
        let details: CentrifugeReplyError = CentrifugeReplyError(
            code: 400,
            message: "bad request",
            temporary: false,
            appCode: 7,
            appType: "PHONE_NUMBER_INVALID",
            metadata: ["field": "phone"]
        )
        let transport: UpdateTransportDouble = UpdateTransportDouble(
            immediate: .failure(CentrifugeError.replyErrorDetails(details))
        )
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "auth.sendCode",
            data: [],
            timeoutSeconds: 30
        )

        let expected: ImpulseCarrierFailure = ImpulseCarrierFailure(
            sdkCode: 400,
            appCode: 7,
            appType: "PHONE_NUMBER_INVALID",
            metadata: ["field": "phone"]
        )
        XCTAssertEqual(result, .failure(expected))
    }


    func testLostConnectionIsANetworkFailure() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(
            immediate: .failure(CentrifugeError.clientDisconnected)
        )
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "help.getConfig",
            data: [],
            timeoutSeconds: 30
        )

        XCTAssertEqual(result, .failure(ImpulseSdkFailure.networkFailure))
    }


    func testCompletionSettlesTheCallOnce() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(
            immediate: .success(Data([4])),
            completeTwice: true
        )
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)

        let result: Result<[UInt8], ImpulseCarrierFailure> = await carrier.send(
            method: "help.getConfig",
            data: [],
            timeoutSeconds: 30
        )

        XCTAssertEqual(result, .success([4]))
    }


    func testCancellingTheTaskCancelsTheCallOnce() async {
        let transport: UpdateTransportDouble = UpdateTransportDouble(immediate: nil)
        let carrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(transport: transport)
        let task: Task<Result<[UInt8], ImpulseCarrierFailure>, Never> = Task {
            return await carrier.send(method: "messages.getHistory", data: [], timeoutSeconds: 30)
        }

        task.cancel()
        let result: Result<[UInt8], ImpulseCarrierFailure> = await task.value

        XCTAssertEqual(transport.cancels(), 1)
        let cancelled: ImpulseCarrierFailure = ImpulseCarrierFailure(sdkCode: 17, appCode: 0, appType: "", metadata: [:])
        XCTAssertEqual(result, .failure(cancelled))
    }


    func testDefaultClientConfigIsTheSocketPolicyWithTheUpdateTimeout() {
        let config: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.defaultClientConfig()

        XCTAssertEqual(config.minReconnectDelay, ImpulseSocketPolicy.minReconnectDelaySeconds)
        XCTAssertEqual(config.maxReconnectDelay, ImpulseSocketPolicy.maxReconnectDelaySeconds)
        XCTAssertEqual(config.maxServerPingDelay, ImpulseSocketPolicy.maxServerPingDelaySeconds)
        XCTAssertEqual(config.timeout, ImpulseRequestTimeouts.updateCallSeconds)
        XCTAssertTrue(config.useNativeWebSocket)
        XCTAssertTrue(config.token.isEmpty)
    }


    func testDefaultClientConfigWithoutRouteSourceHasNoProvider() {
        let config: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.defaultClientConfig(routeSource: nil)

        XCTAssertNil(config.urlSessionConfigurationProvider)
        XCTAssertEqual(config.timeout, ImpulseRequestTimeouts.updateCallSeconds)
    }


    func testDefaultClientConfigWithRouteSourceConnectsThroughItsRoute() {
        let source: UpdateRouteSourceDouble = UpdateRouteSourceDouble(
            route: ImpulseProxyRoute(host: "127.0.0.1", port: 9, username: nil, password: nil)
        )
        let config: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.defaultClientConfig(routeSource: source)

        guard let provider: URLSessionConfigurationProvider = config.urlSessionConfigurationProvider else {
            XCTFail("The route config must carry a provider")
            return
        }
        let proxy: [AnyHashable: Any] = provider().connectionProxyDictionary ?? [:]

        XCTAssertEqual(proxy["HTTPPort"] as? Int, 9)
        XCTAssertEqual(proxy["HTTPSPort"] as? Int, 9)
        XCTAssertEqual(config.timeout, ImpulseRequestTimeouts.updateCallSeconds)
        XCTAssertTrue(config.useNativeWebSocket)
        XCTAssertTrue(config.token.isEmpty)
    }


    func testGivenClientConfigReplacesTheDefault() {
        let given: CentrifugeClientConfig = CentrifugeClientConfig(
            timeout: 45.0,
            minReconnectDelay: 2.0,
            name: "given-update"
        )

        let resolved: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.resolveClientConfig(given)

        XCTAssertEqual(resolved.timeout, 45.0)
        XCTAssertEqual(resolved.minReconnectDelay, 2.0)
        XCTAssertEqual(resolved.name, "given-update")
    }


    func testMissingClientConfigFallsBackToTheDefault() {
        let resolved: CentrifugeClientConfig = ImpulseUpdateSocketCarrier.resolveClientConfig(nil)

        XCTAssertEqual(resolved.timeout, ImpulseRequestTimeouts.updateCallSeconds)
        XCTAssertEqual(resolved.maxReconnectDelay, ImpulseSocketPolicy.maxReconnectDelaySeconds)
    }
}
