import Foundation


/// The kind of a realtime lane, read from its name.
public enum ImpulseLaneKind: Equatable, Sendable {
    case user
    case channel
    case session
    case identity
    case system
    case unknown
}


/// What the application does with one publication once it has been decoded.
public enum ImpulseLaneRoute: Equatable, Sendable {
    /// TL Updates that the application deserializes and processes, with the lane they came on.
    case updates(ImpulseRealtimeUpdates)
    /// A difference that the application runs.
    case difference(ImpulseDifferenceRequest)
    /// Nothing: the publication is not on a realtime lane.
    case ignore
}


/// Routes the decoded publications of every realtime lane. The session, identity and system lanes carry Updates that
/// the application handles by lane, so they are handed over unchanged. A channel body that announces a channel above
/// the member threshold is answered with a difference of that channel.
public struct ImpulseLaneRouter: Sendable {
    public static let sessionLanePrefix: String = "session:"
    public static let identityLanePrefix: String = "identity:"
    public static let systemConfigLane: String = "system:config"

    /// The constructor of the `updates` container, which carries a vector of updates.
    public static let updatesConstructorId: UInt32 = 1957577280

    /// The constructor of `updateShort`, which carries one update.
    public static let updateShortConstructorId: UInt32 = 2027216577

    /// The constructor of `updateChannelTooLong`.
    public static let updateChannelTooLongConstructorId: UInt32 = 277713951

    private let updateConstructorIds: Set<UInt32>


    public init(mapping: ImpulseMapping) {
        self.updateConstructorIds = Set(mapping.constructors(ofType: ImpulseRealtime.updatesTypeName).map { (constructor: ImpulseMappingConstructor) -> UInt32 in
            return constructor.id
        })
    }


    /// The kind of a lane by its name. Names that match no realtime lane give `.unknown`.
    public static func kind(of channel: String) -> ImpulseLaneKind {
        if channel.hasPrefix(ImpulseRealtime.userLanePrefix) {
            return .user
        }

        if channel.hasPrefix(ImpulseRealtime.channelLanePrefix) {
            return .channel
        }

        if channel.hasPrefix(ImpulseLaneRouter.sessionLanePrefix) {
            return .session
        }

        if channel.hasPrefix(ImpulseLaneRouter.identityLanePrefix) {
            return .identity
        }

        if channel == ImpulseLaneRouter.systemConfigLane {
            return .system
        }

        return .unknown
    }


    /// The name of the session lane of one session: `session:{userId}:{sessionHash}`.
    public static func sessionLane(
        userId: Int64,
        sessionHash: Int64
    ) -> String {
        return ImpulseLaneRouter.sessionLanePrefix + String(userId) + ":" + String(sessionHash)
    }


    /// The name of the identity lane of a connection identity: `identity:{identityId}`.
    public static func identityLane(identityId: String) -> String {
        return ImpulseLaneRouter.identityLanePrefix + identityId
    }


    /// The channel of an `updateChannelTooLong` that is the only update of an Updates container, or nil when the
    /// container holds anything else, or is not an Updates container at all.
    public static func channelTooLongId(tl: [UInt8]) -> Int64? {
        do {
            return try readChannelTooLong(tl: tl)
        } catch {
            return nil
        }
    }


    /// Decides what the application does with a decoded TL object published on a lane.
    public func route(
        channel: String,
        tl: [UInt8]
    ) -> ImpulseLaneRoute {
        let kind: ImpulseLaneKind = ImpulseLaneRouter.kind(of: channel)
        if kind == .unknown {
            return .ignore
        }

        switch ImpulseRealtime.classify(tl: tl, updateConstructorIds: updateConstructorIds) {
        case .updatesTooLong:
            return .difference(.account(.updatesTooLong))
        case .unexpected:
            return .difference(.account(.publicationUnexpectedConstructor))
        case .updates:
            if kind == .channel, let channelId: Int64 = ImpulseLaneRouter.channelTooLongId(tl: tl), channelId > 0 {
                return .difference(.channel(channelId: channelId, reason: .updatesTooLong))
            }

            return .updates(ImpulseRealtimeUpdates(channel: channel, tl: tl))
        }
    }


    private static func readChannelTooLong(tl: [UInt8]) throws -> Int64? {
        var reader: ImpulseTlReader = try ImpulseTlReader(data: tl, offset: 0, length: tl.count)
        let head: Int32 = try reader.readInt32()
        let constructor: UInt32 = UInt32(bitPattern: head)

        if constructor == ImpulseLaneRouter.updatesConstructorId {
            let vector: Int32 = try reader.readInt32()
            guard UInt32(bitPattern: vector) == ImpulseTlConstants.vector else {
                return nil
            }

            let count: Int32 = try reader.readInt32()
            guard count == 1 else {
                return nil
            }
        } else if constructor != ImpulseLaneRouter.updateShortConstructorId {
            return nil
        }

        let updateHead: Int32 = try reader.readInt32()
        guard UInt32(bitPattern: updateHead) == ImpulseLaneRouter.updateChannelTooLongConstructorId else {
            return nil
        }

        _ = try reader.readInt32()
        let channelId: Int64 = try reader.readInt64()
        return channelId
    }
}


extension ImpulseRealtimeUpdates {
    /// The kind of the lane these updates came on.
    public var lane: ImpulseLaneKind {
        return ImpulseLaneRouter.kind(of: channel)
    }
}
