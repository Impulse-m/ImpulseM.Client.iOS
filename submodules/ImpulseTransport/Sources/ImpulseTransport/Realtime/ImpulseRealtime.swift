import Foundation
import SwiftCentrifuge


/// Why the application must fetch the difference. The reasons match the realtime client of the Android app.
public enum ImpulseDifferenceReason: String, Equatable, Sendable {
    case subscribeNotRecovered = "subscribe_not_recovered"
    case subscribePositionDropped = "subscribe_position_dropped"
    case publicationDecodeFailed = "publication_decode_failed"
    case publicationUnexpectedConstructor = "publication_unexpected_constructor"
    case updatesTooLong = "updates_too_long"
}


/// A difference the application runs. An account gap fetches the account difference. A channel gap fetches the
/// difference of that channel, and the application falls back to the account difference when that fails.
public enum ImpulseDifferenceRequest: Equatable, Sendable {
    case account(ImpulseDifferenceReason)
    case channel(channelId: Int64, reason: ImpulseDifferenceReason)
}


/// TL Updates decoded from a publication of a lane. The application deserializes and processes them.
public struct ImpulseRealtimeUpdates: Equatable, Sendable {
    public let channel: String
    public let tl: [UInt8]


    public init(
        channel: String,
        tl: [UInt8]
    ) {
        self.channel = channel
        self.tl = tl
    }
}


/// Receives the events of the socket. The socket calls it on its own queue.
public protocol ImpulseRealtimeSocketListener: AnyObject {
    func handleSubscribed(
        channel: String,
        recovered: Bool,
        wasRecovering: Bool
    )

    func handleUnsubscribed(
        channel: String,
        code: Int
    )

    func handlePublication(
        channel: String,
        data: Data
    )
}


/// The connection of the realtime client with its lanes. The app supplies the socket: `ImpulseCentrifugeSocket` on the
/// SwiftCentrifuge client, or a double in tests.
public protocol ImpulseRealtimeSocket: AnyObject {
    var listener: (any ImpulseRealtimeSocketListener)? { get set }

    func connect()

    func disconnect()

    func setConnectionToken(_ token: String)

    func subscribe(
        channel: String,
        positioned: Bool,
        recoverable: Bool
    )

    func unsubscribe(channel: String)
}


/// What a decoded publication body is.
internal enum ImpulseRealtimeBody: Equatable {
    case updates
    case updatesTooLong
    case unexpected
}


/// The realtime side of one account: the user lane, the channel lanes, and the session and identity lanes of one
/// connection. A publication is decoded through the envelope and the transcoder, then routed by lane. Gaps and
/// undecodable publications become difference requests.
///
/// Every public entry point is thread-safe. Handlers run on the thread that reported the event, and never under the lock.
public final class ImpulseRealtime: ImpulseRealtimeSocketListener {
    public static let userLanePrefix: String = "user:"
    public static let channelLanePrefix: String = "channel:"

    /// The constructor of `updatesTooLong`, the only update container the realtime client reads as a difference trigger.
    public static let updatesTooLongConstructorId: UInt32 = 0xE317AF7E

    /// The TL type that every publication body decodes to.
    public static let updatesTypeName: String = "Updates"

    /// Lanes are subscribed positioned and recoverable, and with no other option. The server takes no subscription tokens.
    public static let lanePositioned: Bool = true
    public static let laneRecoverable: Bool = true


    private let transcoder: ImpulseTranscoder
    private let router: ImpulseLaneRouter
    private let socket: any ImpulseRealtimeSocket
    private let lanes: ImpulseLanes
    private let differenceHandler: (ImpulseDifferenceRequest) -> Void
    private let updateHandler: (ImpulseRealtimeUpdates) -> Void
    private let gaps: ImpulseGapTracker = ImpulseGapTracker()
    private let lock: NSLock = NSLock()
    private let laneQueue: DispatchQueue = DispatchQueue(label: "net.impulsem.transport.realtime-lanes")

    private var userLaneId: Int64 = 0
    private var channelLanes: Set<Int64> = []
    private var laneCandidates: [ImpulseLaneCandidate] = []
    private var openedChannelId: Int64 = 0
    private var pendingRecompute: DispatchWorkItem? = nil
    private var sessionLaneName: String? = nil
    private var identityLaneName: String? = nil


    public init(
        mapping: ImpulseMapping,
        socket: any ImpulseRealtimeSocket,
        lanes: ImpulseLanes = ImpulseLanes(),
        differenceHandler: @escaping (ImpulseDifferenceRequest) -> Void,
        updateHandler: @escaping (ImpulseRealtimeUpdates) -> Void
    ) {
        self.transcoder = ImpulseTranscoder(mapping: mapping)
        self.router = ImpulseLaneRouter(mapping: mapping)
        self.socket = socket
        self.lanes = lanes
        self.differenceHandler = differenceHandler
        self.updateHandler = updateHandler
        self.socket.listener = self
    }


    /// Runs the actions of one sync plan in a fixed order: drop the user lane, stop the channel lanes, disconnect,
    /// subscribe the user lane, connect.
    public func apply(plan: ImpulseSyncPlan) {
        if plan.dropUserLane != 0 {
            dropUserLane(plan.dropUserLane)
        }

        if plan.stopLanes {
            stopChannelLanes()
        }

        if plan.disconnect {
            socket.disconnect()
        }

        if plan.subscribeUserLane != 0 {
            subscribeUserLane(plan.subscribeUserLane)
        }

        if plan.connect {
            socket.connect()
        }
    }


    /// Rekeys the socket to a new connection token: the socket drops, takes the token and connects again.
    public func rekey(token: String) {
        socket.disconnect()
        socket.setConnectionToken(token)
        socket.connect()
    }


    /// Records the lane inputs and recomputes the channel lanes after the debounce of the lane selector.
    public func updateLanes(
        candidates: [ImpulseLaneCandidate],
        openedChannelId: Int64
    ) {
        let work: DispatchWorkItem = DispatchWorkItem { [weak self] in
            self?.recomputeLanes()
        }

        lock.lock()
        self.laneCandidates = candidates
        self.openedChannelId = openedChannelId
        let previous: DispatchWorkItem? = pendingRecompute
        pendingRecompute = work
        let delay: Int = lanes.debounceMilliseconds
        lock.unlock()

        previous?.cancel()
        laneQueue.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.milliseconds(delay), execute: work)
    }


    /// Records the lane inputs and recomputes the channel lanes at once.
    public func applyLanes(
        candidates: [ImpulseLaneCandidate],
        openedChannelId: Int64
    ) {
        lock.lock()
        self.laneCandidates = candidates
        self.openedChannelId = openedChannelId
        let previous: DispatchWorkItem? = pendingRecompute
        pendingRecompute = nil
        lock.unlock()

        previous?.cancel()
        recomputeLanes()
    }


    /// Subscribes the session lane `session:{userId}:{sessionHash}`, which carries the call signalling and the call states
    /// addressed to this session. A different session replaces the lane.
    public func subscribeSessionLane(
        userId: Int64,
        sessionHash: Int64
    ) {
        let name: String = ImpulseLaneRouter.sessionLane(userId: userId, sessionHash: sessionHash)

        lock.lock()
        let previous: String? = sessionLaneName
        sessionLaneName = name
        lock.unlock()

        if previous == name {
            return
        }

        if let stale: String = previous {
            socket.unsubscribe(channel: stale)
        }

        socket.subscribe(
            channel: name,
            positioned: ImpulseRealtime.lanePositioned,
            recoverable: ImpulseRealtime.laneRecoverable
        )
    }


    /// Drops the session lane when one is subscribed.
    public func dropSessionLane() {
        lock.lock()
        let previous: String? = sessionLaneName
        sessionLaneName = nil
        lock.unlock()

        if let stale: String = previous {
            socket.unsubscribe(channel: stale)
        }
    }


    /// Subscribes the identity lane `identity:{identityId}`, which carries the QR login of a signed-out slot.
    public func subscribeIdentityLane(identityId: String) {
        guard !identityId.isEmpty else {
            return
        }

        let name: String = ImpulseLaneRouter.identityLane(identityId: identityId)

        lock.lock()
        let previous: String? = identityLaneName
        identityLaneName = name
        lock.unlock()

        if previous == name {
            return
        }

        if let stale: String = previous {
            socket.unsubscribe(channel: stale)
        }

        socket.subscribe(
            channel: name,
            positioned: ImpulseRealtime.lanePositioned,
            recoverable: ImpulseRealtime.laneRecoverable
        )
    }


    /// Drops the identity lane when one is subscribed.
    public func dropIdentityLane() {
        lock.lock()
        let previous: String? = identityLaneName
        identityLaneName = nil
        lock.unlock()

        if let stale: String = previous {
            socket.unsubscribe(channel: stale)
        }
    }


    public func handleSubscribed(
        channel: String,
        recovered: Bool,
        wasRecovering: Bool
    ) {
        let needsDifference: Bool = gaps.onSubscribed(channel: channel, recovered: recovered, wasRecovering: wasRecovering)
        if needsDifference {
            let reason: ImpulseDifferenceReason = recovered ? .subscribePositionDropped : .subscribeNotRecovered
            requestDifference(channel: channel, reason: reason)
        }

        if channel.hasPrefix(ImpulseRealtime.userLanePrefix) {
            recomputeLanes()
        }
    }


    public func handleUnsubscribed(
        channel: String,
        code: Int
    ) {
        gaps.onUnsubscribed(channel: channel, code: code)
    }


    public func handlePublication(
        channel: String,
        data: Data
    ) {
        if ImpulseLaneRouter.kind(of: channel) == .unknown {
            return
        }

        switch ImpulseEnvelope.parse(bytes: data) {
        case .undecodable:
            differenceHandler(.account(.publicationDecodeFailed))
        case .legacySessionRevoked:
            return
        case .envelope(let envelope):
            decode(channel: channel, envelope: envelope)
        }
    }


    /// Sorts a decoded TL object: the `updatesTooLong` container, a regular Updates constructor, or anything else.
    internal static func classify(
        tl: [UInt8],
        updateConstructorIds: Set<UInt32>
    ) -> ImpulseRealtimeBody {
        guard let constructor: UInt32 = constructorId(tl: tl) else {
            return .unexpected
        }

        if constructor == ImpulseRealtime.updatesTooLongConstructorId {
            return .updatesTooLong
        }

        if updateConstructorIds.contains(constructor) {
            return .updates
        }

        return .unexpected
    }


    /// The little-endian constructor id at the start of a TL object, or nil when the object is shorter than an id.
    internal static func constructorId(tl: [UInt8]) -> UInt32? {
        guard tl.count >= 4 else {
            return nil
        }

        var value: UInt32 = 0
        for index: Int in 0..<4 {
            value |= UInt32(tl[index]) << UInt32(8 * index)
        }
        return value
    }


    /// The channel id of a `channel:{id}` lane, or nil for any other name or a non-positive id.
    internal static func channelId(of channel: String) -> Int64? {
        guard channel.hasPrefix(ImpulseRealtime.channelLanePrefix) else {
            return nil
        }

        let text: String = String(channel.dropFirst(ImpulseRealtime.channelLanePrefix.count))
        guard let value: Int64 = Int64(text), value > 0 else {
            return nil
        }
        return value
    }


    private func decode(
        channel: String,
        envelope: ImpulseEnvelope
    ) {
        let tl: [UInt8]
        do {
            tl = try transcoder.protoToTlObject(
                typeName: ImpulseRealtime.updatesTypeName,
                proto: [UInt8](envelope.body),
                capture: nil
            )
        } catch {
            differenceHandler(.account(.publicationDecodeFailed))
            return
        }

        switch router.route(channel: channel, tl: tl) {
        case .updates(let updates):
            updateHandler(updates)
        case .difference(let request):
            differenceHandler(request)
        case .ignore:
            break
        }
    }


    /// Requests the difference of a lane whose position was lost. A user lane asks for the account difference, and a channel
    /// lane for the difference of that channel. Undecodable publications never come here: they always ask for the account difference.
    /// The session lane asks for the account difference, because its call states are durable there. The identity and
    /// system lanes ask for nothing.
    private func requestDifference(
        channel: String,
        reason: ImpulseDifferenceReason
    ) {
        switch ImpulseLaneRouter.kind(of: channel) {
        case .user, .session:
            differenceHandler(.account(reason))
        case .channel:
            if let channelId: Int64 = ImpulseRealtime.channelId(of: channel) {
                differenceHandler(.channel(channelId: channelId, reason: reason))
            }
        case .identity, .system, .unknown:
            break
        }
    }


    private func dropUserLane(_ userId: Int64) {
        socket.unsubscribe(channel: ImpulseRealtime.userLanePrefix + String(userId))

        lock.lock()
        if userLaneId == userId {
            userLaneId = 0
        }
        lock.unlock()
    }


    private func subscribeUserLane(_ userId: Int64) {
        lock.lock()
        userLaneId = userId
        lock.unlock()

        socket.subscribe(
            channel: ImpulseRealtime.userLanePrefix + String(userId),
            positioned: ImpulseRealtime.lanePositioned,
            recoverable: ImpulseRealtime.laneRecoverable
        )
    }


    private func stopChannelLanes() {
        lock.lock()
        let stale: [Int64] = channelLanes.sorted()
        channelLanes.removeAll()
        let work: DispatchWorkItem? = pendingRecompute
        pendingRecompute = nil
        lock.unlock()

        work?.cancel()
        for channelId: Int64 in stale {
            socket.unsubscribe(channel: ImpulseRealtime.channelLanePrefix + String(channelId))
        }
    }


    /// Diffs the channel lanes against the selection. Channel lanes exist only while the user lane is set.
    private func recomputeLanes() {
        lock.lock()
        pendingRecompute = nil
        let selected: [Int64] = userLaneId == 0 ? [] : lanes.select(candidates: laneCandidates, openedChannelId: openedChannelId)
        let desired: Set<Int64> = Set(selected)
        let toDrop: [Int64] = channelLanes.subtracting(desired).sorted()
        let toAdd: [Int64] = selected.filter { (channelId: Int64) -> Bool in
            return !channelLanes.contains(channelId)
        }
        channelLanes = desired
        lock.unlock()

        for channelId: Int64 in toDrop {
            socket.unsubscribe(channel: ImpulseRealtime.channelLanePrefix + String(channelId))
        }

        for channelId: Int64 in toAdd {
            socket.subscribe(
                channel: ImpulseRealtime.channelLanePrefix + String(channelId),
                positioned: ImpulseRealtime.lanePositioned,
                recoverable: ImpulseRealtime.laneRecoverable
            )
        }
    }
}


/// The socket of the realtime client on a SwiftCentrifuge client: the connection, and one subscription per lane.
public final class ImpulseCentrifugeSocket: ImpulseRealtimeSocket {
    public weak var listener: (any ImpulseRealtimeSocketListener)?

    private let client: CentrifugeClient
    private let lock: NSLock = NSLock()
    private var bridges: [String: ImpulseSubscriptionBridge] = [:]


    public init(client: CentrifugeClient) {
        self.client = client
    }


    public func connect() {
        client.connect()
    }


    public func disconnect() {
        client.disconnect()
    }


    public func setConnectionToken(_ token: String) {
        client.setToken(token: token)
    }


    public func subscribe(
        channel: String,
        positioned: Bool,
        recoverable: Bool
    ) {
        if let existing: CentrifugeSubscription = client.getSubscription(channel: channel) {
            existing.subscribe()
            return
        }

        let bridge: ImpulseSubscriptionBridge = ImpulseSubscriptionBridge(channel: channel, owner: self)
        let config: CentrifugeSubscriptionConfig = CentrifugeSubscriptionConfig(
            positioned: positioned,
            recoverable: recoverable
        )
        guard let subscription: CentrifugeSubscription = try? client.newSubscription(
            channel: channel,
            delegate: bridge,
            config: config
        ) else {
            return
        }

        lock.lock()
        bridges[channel] = bridge
        lock.unlock()

        subscription.subscribe()
    }


    public func unsubscribe(channel: String) {
        lock.lock()
        bridges[channel] = nil
        lock.unlock()

        guard let subscription: CentrifugeSubscription = client.getSubscription(channel: channel) else {
            return
        }
        client.removeSubscription(subscription)
    }


    internal func deliverSubscribed(
        channel: String,
        recovered: Bool,
        wasRecovering: Bool
    ) {
        listener?.handleSubscribed(channel: channel, recovered: recovered, wasRecovering: wasRecovering)
    }


    internal func deliverUnsubscribed(
        channel: String,
        code: Int
    ) {
        listener?.handleUnsubscribed(channel: channel, code: code)
    }


    internal func deliverPublication(
        channel: String,
        data: Data
    ) {
        listener?.handlePublication(channel: channel, data: data)
    }
}


/// Forwards the events of one lane subscription to the socket that owns it.
internal final class ImpulseSubscriptionBridge: CentrifugeSubscriptionDelegate {
    private let channel: String
    private weak var owner: ImpulseCentrifugeSocket?


    internal init(
        channel: String,
        owner: ImpulseCentrifugeSocket
    ) {
        self.channel = channel
        self.owner = owner
    }


    internal func onSubscribed(
        _ sub: CentrifugeSubscription,
        _ event: CentrifugeSubscribedEvent
    ) {
        owner?.deliverSubscribed(channel: channel, recovered: event.recovered, wasRecovering: event.wasRecovering)
    }


    internal func onUnsubscribed(
        _ sub: CentrifugeSubscription,
        _ event: CentrifugeUnsubscribedEvent
    ) {
        owner?.deliverUnsubscribed(channel: channel, code: Int(event.code))
    }


    internal func onPublication(
        _ sub: CentrifugeSubscription,
        _ event: CentrifugePublicationEvent
    ) {
        owner?.deliverPublication(channel: channel, data: event.data)
    }
}
