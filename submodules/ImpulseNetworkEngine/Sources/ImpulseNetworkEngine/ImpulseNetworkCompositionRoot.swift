import Foundation
import SwiftCentrifuge
import TelegramCore
import ImpulseTransport


/// What the composition root takes from its caller. The app supplies the system keychain and the production endpoints;
/// the tests supply doubles.
struct ImpulseNetworkCompositionInputs {
    let endpoints: ImpulseEndpoints
    let mapping: ImpulseMapping
    let keychain: any ImpulseKeychain
    let keychainAccessGroup: String?
    let identityClock: any ImpulseIdentityClock
    let identityScheduler: any ImpulseIdentityScheduler
    let declaration: ImpulseDeclaration
    let updateBridge: ImpulseUpdateBridge
    let routeSource: ImpulseProxyRouteSource?
}


/// The update socket as a route epoch uses it: the reconnect over the new route, and the disconnect while the root stops.
protocol ImpulseRouteUpdateSocket: AnyObject {
    func connect()

    func disconnect()
}


/// The pool as a route epoch uses it: its start and stop, and the reset of its main client after a route change.
protocol ImpulseRoutePool: AnyObject {
    func start()

    func stop()

    func resetMain()
}


/// The media fleet as a route epoch uses it: the reset that retires the carrier and fails the waiting calls.
protocol ImpulseRouteMediaFleet: AnyObject {
    func reset()
}


/// The request service as a route epoch uses it: the advance of the route epoch that classifies the calls in flight.
protocol ImpulseRouteEpochSink: AnyObject {
    func advanceRouteEpoch()
}


/// The parts that a route epoch touches, as seams. A nil seam is the real part, reached through an adapter. The tests
/// pass fakes for the seams, so that no socket connects and no server is reached.
struct ImpulseNetworkRouteSeams {
    let updateSocket: (any ImpulseRouteUpdateSocket)?
    let pool: (any ImpulseRoutePool)?
    let mediaFleet: (any ImpulseRouteMediaFleet)?
    let epochSink: (any ImpulseRouteEpochSink)?
}


/// The update client of the root as a route epoch uses it.
private final class ImpulseRootUpdateSocketAdapter: ImpulseRouteUpdateSocket {
    private let client: CentrifugeClient


    init(client: CentrifugeClient) {
        self.client = client
    }


    func connect() {
        self.client.connect()
    }


    func disconnect() {
        self.client.disconnect()
    }
}


/// The pool carrier of the root as a route epoch uses it.
private final class ImpulseRootPoolAdapter: ImpulseRoutePool {
    private let pool: ImpulsePoolCarrier


    init(pool: ImpulsePoolCarrier) {
        self.pool = pool
    }


    func start() {
        self.pool.start()
    }


    func stop() {
        self.pool.stop()
    }


    func resetMain() {
        self.pool.resetMain()
    }
}


/// The media fleet of the root as a route epoch uses it.
private final class ImpulseRootMediaFleetAdapter: ImpulseRouteMediaFleet {
    private let fleet: ImpulseMediaFleet


    init(fleet: ImpulseMediaFleet) {
        self.fleet = fleet
    }


    func reset() {
        self.fleet.reset()
    }
}


/// The request service of the root as a route epoch uses it.
private final class ImpulseRootEpochAdapter: ImpulseRouteEpochSink {
    private let service: ImpulseRequestService


    init(service: ImpulseRequestService) {
        self.service = service
    }


    func advanceRouteEpoch() {
        self.service.advanceRouteEpoch()
    }
}


/// The composition root of one account's ImpulseM transport. It builds the parts of `ImpulseTransport` that the sessions
/// share (the endpoints, the codec, the session tokens and the connection identity, the update socket and the pool clients
/// with their carriers, the media fleet, the connection declaration, the request service, the realtime client and the
/// telemetry), and it creates the sessions of the engine on them.
///
/// The update socket and the pool use the socket policy of the transport: reconnects back off from 1 to 30 seconds, and the
/// ping watchdog runs on the server's ping delay. The update socket presents the access token of the session, or the connection
/// identity while there is no session.
final class ImpulseNetworkCompositionRoot: ImpulseNetworkLifecycle, ImpulseNetworkTransportControl {
    let transcoder: ImpulseTranscoder
    let sessionStore: ImpulseSessionStore
    let credentials: ImpulseConnectionCredentialCache
    let tokens: ImpulseTokens
    let identity: ImpulseIdentityManager
    let pool: ImpulsePoolCarrier
    let poolRequestCarrier: ImpulsePoolRequestCarrier
    let updateClient: CentrifugeClient
    let updateSocket: ImpulseCentrifugeSocket
    let updateCarrier: ImpulseUpdateSocketCarrier
    let mediaFleet: ImpulseMediaFleet
    let mediaCarrier: ImpulseMediaRequestCarrier
    let declarer: ImpulseConnectionDeclarer
    let requestService: ImpulseRequestService
    let loginGate: ImpulseLoginGate
    let sessionInstaller: ImpulseSessionInstaller
    let telemetry: ImpulseTelemetry
    let realtime: ImpulseRealtime
    let forwarder: ImpulseRealtimeForwarder

    /// The queue the route epochs run on, in order. A test flushes it by running an empty block on it.
    let routeQueue: DispatchQueue = DispatchQueue(label: "org.impulsem.network-engine.route-epochs")

    private let identityCarrier: ImpulsePoolIdentityCarrier
    private let declaration: ImpulseDeclaration
    private let updateBridge: ImpulseUpdateBridge
    private let routeSource: ImpulseProxyRouteSource?
    private let routeUpdateSocket: any ImpulseRouteUpdateSocket
    private let routePool: any ImpulseRoutePool
    private let routeMediaFleet: any ImpulseRouteMediaFleet
    private let routeEpochSink: any ImpulseRouteEpochSink
    private let lock: NSLock = NSLock()
    private var started: Bool = false
    private var paused: Bool = false
    private var observingRoutes: Bool = false
    private var routeObservation: ImpulseProxyRouteObservation? = nil
    private var lastRouteEpoch: Int? = nil


    convenience init(inputs: ImpulseNetworkCompositionInputs) throws {
        try self.init(inputs: inputs, seams: nil)
    }


    /// Builds the root. A nil `seams` builds the real parts that a route epoch touches; the tests pass fakes for them.
    init(
        inputs: ImpulseNetworkCompositionInputs,
        seams: ImpulseNetworkRouteSeams?
    ) throws {
        let link: ImpulseAccountLink = ImpulseAccountLink()
        let forwarder: ImpulseRealtimeForwarder = ImpulseRealtimeForwarder()
        let transcoder: ImpulseTranscoder = ImpulseTranscoder(mapping: inputs.mapping)
        let store: ImpulseSessionStore = ImpulseSessionStore(
            accountIndex: 0,
            accessGroup: inputs.keychainAccessGroup,
            keychain: inputs.keychain
        )
        let credentials: ImpulseConnectionCredentialCache = ImpulseConnectionCredentialCache()

        let pool: ImpulsePoolCarrier = try ImpulsePoolCarrier(
            endpoint: inputs.endpoints.poolUrl(),
            identityRenewal: { (completion: @escaping (Result<Void, Error>) -> Void) -> Void in
                link.renewIdentity(completion: completion)
            },
            mainConfig: ImpulseNetworkCompositionRoot.makePoolConfig(routeSource: inputs.routeSource)
        )
        let poolRequestCarrier: ImpulsePoolRequestCarrier = ImpulsePoolRequestCarrier(pool: pool)
        let identityCarrier: ImpulsePoolIdentityCarrier = ImpulsePoolIdentityCarrier(carrier: poolRequestCarrier)
        let identity: ImpulseIdentityManager = ImpulseIdentityManager(
            poolCarrier: identityCarrier,
            store: store.identityStore(),
            clock: inputs.identityClock,
            scheduler: inputs.identityScheduler,
            apiId: inputs.declaration.apiId
        )

        let updateClient: CentrifugeClient = ImpulseUpdateSocketCarrier.makeClient(
            endpoint: inputs.endpoints.realtimeUrl(),
            config: ImpulseNetworkCompositionRoot.makeUpdateConfig(
                tokenGetter: ImpulseNetworkCompositionRoot.connectionTokenGetter(link: link),
                routeSource: inputs.routeSource
            )
        )
        let updateSocket: ImpulseCentrifugeSocket = ImpulseCentrifugeSocket(client: updateClient)
        let updateCarrier: ImpulseUpdateSocketCarrier = ImpulseUpdateSocketCarrier(client: updateClient)

        let mediaRouteSource: ImpulseProxyRouteSource? = inputs.routeSource
        let mediaFleet: ImpulseMediaFleet = ImpulseMediaFleet(makeTransport: { (endpoint: String) -> ImpulseMediaTransport in
            return ImpulseNetworkCompositionRoot.makeMediaTransport(
                endpoint: endpoint,
                tokenGetter: ImpulseNetworkCompositionRoot.mediaTokenGetter(link: link),
                routeSource: mediaRouteSource
            )
        })
        let mediaCarrier: ImpulseMediaRequestCarrier = ImpulseMediaRequestCarrier(fleet: mediaFleet)

        let refreshTransport: ImpulseCarrierRefreshTransport = ImpulseCarrierRefreshTransport(
            updateSocket: updateCarrier,
            poolFleet: poolRequestCarrier
        )
        let tokens: ImpulseTokens = ImpulseTokens(storage: store, transport: refreshTransport)
        let declarer: ImpulseConnectionDeclarer = ImpulseConnectionDeclarer(
            carrier: updateCarrier,
            credentials: credentials,
            reporter: { (outcome: ImpulseDeclarationOutcome, attempt: Int, code: Int) -> Void in
                Logger.shared.log("ImpulseNetwork", "The connection declaration: \(outcome.rawValue), attempt \(attempt), error \(code)")
            }
        )
        let loginGate: ImpulseLoginGate = ImpulseLoginGate(isOpen: store.isLoggedIn)
        let requestService: ImpulseRequestService = ImpulseRequestService(
            session: tokens,
            updateCarrier: updateCarrier,
            mediaCarrier: mediaCarrier,
            poolCarrier: poolRequestCarrier,
            declarations: declarer,
            signedIn: store.isLoggedIn,
            onAuthorizationRequired: {},
            loginGate: loginGate,
            identityTag: ImpulseNetworkCompositionRoot.identityTagSource(identity: identity)
        )
        let telemetry: ImpulseTelemetry = ImpulseTelemetry(
            sink: ImpulseRequestTelemetrySink(transcoder: transcoder, requester: requestService)
        )

        let realtime: ImpulseRealtime = ImpulseRealtime(
            mapping: inputs.mapping,
            socket: updateSocket,
            lanes: ImpulseLanes(),
            differenceHandler: { (request: ImpulseDifferenceRequest) -> Void in
                forwarder.forward(difference: request)
            },
            updateHandler: { (updates: ImpulseRealtimeUpdates) -> Void in
                forwarder.forward(updates: updates)
            }
        )

        let sessionInstaller: ImpulseSessionInstaller = ImpulseSessionInstaller(
            identity: identity,
            tokens: tokens,
            realtime: realtime,
            mapping: inputs.mapping,
            setSignedIn: { (signedIn: Bool) -> Void in
                loginGate.setOpen(signedIn)
            },
            credentials: credentials,
            declarer: declarer,
            mediaFleet: mediaFleet
        )

        link.bind(parts: ImpulseAccountParts(tokens: tokens, identity: identity, credentials: credentials, declarer: declarer))

        let routeUpdateSocket: any ImpulseRouteUpdateSocket = seams?.updateSocket ?? ImpulseRootUpdateSocketAdapter(client: updateClient)
        let routePool: any ImpulseRoutePool = seams?.pool ?? ImpulseRootPoolAdapter(pool: pool)
        let routeMediaFleet: any ImpulseRouteMediaFleet = seams?.mediaFleet ?? ImpulseRootMediaFleetAdapter(fleet: mediaFleet)
        let routeEpochSink: any ImpulseRouteEpochSink = seams?.epochSink ?? ImpulseRootEpochAdapter(service: requestService)

        self.transcoder = transcoder
        self.sessionStore = store
        self.credentials = credentials
        self.tokens = tokens
        self.identity = identity
        self.pool = pool
        self.poolRequestCarrier = poolRequestCarrier
        self.identityCarrier = identityCarrier
        self.updateClient = updateClient
        self.updateSocket = updateSocket
        self.updateCarrier = updateCarrier
        self.mediaFleet = mediaFleet
        self.mediaCarrier = mediaCarrier
        self.declarer = declarer
        self.requestService = requestService
        self.loginGate = loginGate
        self.sessionInstaller = sessionInstaller
        self.telemetry = telemetry
        self.realtime = realtime
        self.forwarder = forwarder
        self.declaration = inputs.declaration
        self.updateBridge = inputs.updateBridge
        self.routeSource = inputs.routeSource
        self.routeUpdateSocket = routeUpdateSocket
        self.routePool = routePool
        self.routeMediaFleet = routeMediaFleet
        self.routeEpochSink = routeEpochSink
    }


    /// The socket policy of the update socket: the 1 to 30 second reconnect backoff, the ping watchdog, and the call timeout
    /// of the update calls, which the SDK requires to be at least the call deadline. The token getter supplies the connection token.
    /// The socket connects through the route of `routeSource`, or directly when it is nil.
    static func makeUpdateConfig(
        tokenGetter: CentrifugeConnectionTokenGetter?,
        routeSource: ImpulseProxyRouteSource? = nil
    ) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "", routeSource: routeSource)
        config.timeout = ImpulseRequestTimeouts.updateCallSeconds
        config.tokenGetter = tokenGetter
        return config
    }


    /// The socket policy of the pool's main client: the same backoff and watchdog, the pool's client name and call timeout, and no token.
    /// The main client connects through the route of `routeSource`, or directly when it is nil.
    static func makePoolConfig(routeSource: ImpulseProxyRouteSource? = nil) -> CentrifugeClientConfig {
        var config: CentrifugeClientConfig = ImpulseSocketPolicy.clientConfig(token: "", routeSource: routeSource)
        config.name = ImpulsePoolCarrier.clientName
        config.timeout = ImpulsePoolCarrier.callTimeoutSeconds
        return config
    }


    /// The transport of one media endpoint: a socket client with the media connection token, which connects through the route
    /// of `routeSource`, or directly when it is nil.
    static func makeMediaTransport(
        endpoint: String,
        tokenGetter: @escaping CentrifugeConnectionTokenGetter,
        routeSource: ImpulseProxyRouteSource?
    ) -> ImpulseMediaTransport {
        return ImpulseMediaSocketTransport(
            endpoint: endpoint,
            tokenGetter: tokenGetter,
            routeSource: routeSource
        )
    }


    /// The role of a session of the engine as the transport names it.
    static func sessionRole(_ role: NetworkEngineSessionRole) -> ImpulseSessionRole {
        switch role {
        case .main:
            return .main

        case .worker(let masterDatacenterId, let isMedia, let isCdn):
            return .worker(masterDatacenterId: masterDatacenterId, isMedia: isMedia, isCdn: isCdn)
        }
    }


    /// The diagnostic tag of the identity the socket presents: the hash of its subject and its `orig_iat`. It never carries the token.
    static func identityTagSource(identity: ImpulseIdentityManager) -> @Sendable () async -> String? {
        return { () async -> String? in
            let token: String? = await identity.current()
            return ImpulseDiagnostics.identityTag(token: token)
        }
    }


    static func connectionTokenGetter(link: ImpulseAccountLink) -> CentrifugeConnectionTokenGetter {
        return { (_ event: CentrifugeConnectionTokenEvent, _ completion: @escaping (Result<String, Error>) -> Void) -> Void in
            link.connectionToken(completion: completion)
        }
    }


    static func mediaTokenGetter(link: ImpulseAccountLink) -> CentrifugeConnectionTokenGetter {
        return { (_ event: CentrifugeConnectionTokenEvent, _ completion: @escaping (Result<String, Error>) -> Void) -> Void in
            link.mediaToken(completion: completion)
        }
    }


    /// Starts the account's connections: the pool connects its main client, the stored identity is loaded and scheduled for
    /// renewal, the credential cache follows the session and the identity, the declaration is set on the update socket, and
    /// the route epochs of the route source are followed. A start while started changes nothing.
    func start() {
        self.lock.lock()
        let alreadyStarted: Bool = self.started
        self.started = true
        self.lock.unlock()
        if alreadyStarted {
            return
        }

        self.startRouteObservation()
        self.routePool.start()

        let identity: ImpulseIdentityManager = self.identity
        let identityCarrier: ImpulsePoolIdentityCarrier = self.identityCarrier
        let tokens: ImpulseTokens = self.tokens
        let credentials: ImpulseConnectionCredentialCache = self.credentials
        let declarer: ImpulseConnectionDeclarer = self.declarer
        let declaration: ImpulseDeclaration = self.declaration
        Task {
            await identity.setRenewalCarrier(identityCarrier)
            await identity.start()
            await credentials.follow(tokens: tokens, identity: identity)
            await declarer.setDeclaration(declaration)
        }
    }


    /// Follows the route epochs of the route source, so that each epoch reaches `applyRouteEpoch` on the route queue. The
    /// start calls it; a call while the route is already observed changes nothing.
    func startRouteObservation() {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        if self.observingRoutes {
            return
        }
        self.observingRoutes = true
        self.routeObservation = self.routeSource?.observe({ [weak self] (epoch: Int) -> Void in
            if let root: ImpulseNetworkCompositionRoot = self {
                root.routeQueue.async {
                    root.applyRouteEpoch(epoch)
                }
            }
        })
    }


    /// Stops the connections. The route observation is cancelled, the pool stops restarting its main client, and the update socket disconnects.
    func stop() {
        self.lock.lock()
        self.started = false
        self.observingRoutes = false
        let observation: ImpulseProxyRouteObservation? = self.routeObservation
        self.routeObservation = nil
        self.lock.unlock()

        observation?.cancel()
        self.routePool.stop()
        self.routeUpdateSocket.disconnect()
    }


    /// Drops the update socket while the sessions are paused, and connects it again on resume. The sessions reconnect on their own
    /// within the socket policy.
    func setPaused(_ paused: Bool) {
        self.lock.lock()
        self.paused = paused
        self.lock.unlock()

        if paused {
            self.routeUpdateSocket.disconnect()
        } else {
            self.routeUpdateSocket.connect()
        }
    }


    /// The keepalive of the socket follows the SDK's ping watchdog, which does not depend on the user's presence.
    func setOnline(_ online: Bool) {
    }


    /// Creates one session of the engine. The main session becomes the receiver of the realtime client; a worker session does not.
    func makeSession(
        datacenterId: Int,
        role: NetworkEngineSessionRole,
        delegate: NetworkEngineSessionDelegate?
    ) -> NetworkEngineSession {
        let isMain: Bool = role == .main
        let control: ImpulseNetworkTransportControl?
        if isMain {
            control = self
        } else {
            control = nil
        }
        let session: ImpulseNetworkEngineSession = ImpulseNetworkEngineSession(
            datacenterId: datacenterId,
            role: role,
            delegate: delegate,
            updateBridge: self.updateBridge,
            timing: ImpulseNetworkRetryTiming.canonical,
            control: control,
            onParseFailure: {
                Logger.shared.log("ImpulseNetwork", "A reply of datacenter \(datacenterId) did not parse")
            },
            makeTransport: { (events: ImpulseNetworkSessionEvents) -> ImpulseNetworkSession in
                return self.makeTransport(
                    datacenterId: datacenterId,
                    role: role,
                    events: events
                )
            }
        )
        if isMain {
            self.forwarder.setDelivery(session.transport)
        }
        return session
    }


    /// Applies one route epoch on the route queue. A repeated or older epoch does nothing, and so does an epoch while the route
    /// is not observed (before the observation starts, or after `stop`). Otherwise the request service advances its route epoch,
    /// so the calls in flight are classified as route failures, the update socket reconnects once over the new route (while
    /// paused it is left down, and connects on resume over the current route), and the pool main and the media fleet are reset.
    private func applyRouteEpoch(_ epoch: Int) {
        self.lock.lock()
        var repeated: Bool = false
        if let last: Int = self.lastRouteEpoch {
            repeated = epoch <= last
        }
        let observing: Bool = self.observingRoutes
        let isPaused: Bool = self.paused
        if repeated || !observing {
            self.lock.unlock()
            return
        }
        self.lastRouteEpoch = epoch
        self.routeEpochSink.advanceRouteEpoch()
        if !isPaused {
            self.routeUpdateSocket.disconnect()
            self.routeUpdateSocket.connect()
        }
        self.routePool.resetMain()
        self.routeMediaFleet.reset()
        self.lock.unlock()
    }


    private func makeTransport(
        datacenterId: Int,
        role: NetworkEngineSessionRole,
        events: ImpulseNetworkSessionEvents
    ) -> ImpulseNetworkSession {
        return ImpulseNetworkSession(
            datacenterId: datacenterId,
            role: ImpulseNetworkCompositionRoot.sessionRole(role),
            transcoder: self.transcoder,
            session: self.tokens,
            updateCarrier: self.updateCarrier,
            mediaCarrier: self.mediaCarrier,
            poolCarrier: self.poolRequestCarrier,
            declarations: self.declarer,
            signedIn: self.sessionStore.isLoggedIn,
            delegate: events,
            loginGate: self.loginGate,
            identityTag: ImpulseNetworkCompositionRoot.identityTagSource(identity: self.identity),
            sessionInstaller: self.sessionInstaller
        )
    }
}
