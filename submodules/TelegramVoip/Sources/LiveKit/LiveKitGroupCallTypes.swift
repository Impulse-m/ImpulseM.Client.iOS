import Foundation


/// The key of an audio level in a group LiveKit call: the local microphone, or a remote source by its SSRC.
public enum LiveKitGroupAudioLevelKey: Hashable {
    case local
    case source(UInt32)
}


/// The network state of a group LiveKit call, in the shape the group call UI reads.
public struct LiveKitGroupNetworkState: Equatable {
    public let isConnected: Bool
    public let isTransitioningFromBroadcastToRtc: Bool
    public let isBroadcast: Bool


    public init(
        isConnected: Bool,
        isTransitioningFromBroadcastToRtc: Bool,
        isBroadcast: Bool
    ) {
        self.isConnected = isConnected
        self.isTransitioningFromBroadcastToRtc = isTransitioningFromBroadcastToRtc
        self.isBroadcast = isBroadcast
    }


    /// Only a connected room is connected. LiveKit calls have no broadcast or RTMP mode, so both flags are false.
    public init(state: LiveKitGroupCallState) {
        self.init(
            isConnected: state == .connected,
            isTransitioningFromBroadcastToRtc: false,
            isBroadcast: false
        )
    }
}


/// The kind of the peer that owns a group participant identity.
public enum LiveKitGroupIdentityKind: Equatable {
    case user
    case chat
    case channel
}


/// A parsed group participant identity, `<k><peerId>.<source>` with an optional `.p` suffix.
public struct LiveKitGroupIdentity: Equatable {
    public let kind: LiveKitGroupIdentityKind
    public let peerId: Int64
    public let source: UInt32
    public let isPresentation: Bool


    public init(
        kind: LiveKitGroupIdentityKind,
        peerId: Int64,
        source: UInt32,
        isPresentation: Bool
    ) {
        self.kind = kind
        self.peerId = peerId
        self.source = source
        self.isPresentation = isPresentation
    }


    /// Parses an identity. Validation is shared with `LiveKitIdentity.groupSource(identity:)`, so the same values are rejected.
    public static func parse(identity: String) throws -> LiveKitGroupIdentity {
        let signedSource: Int32 = try LiveKitIdentity.groupSource(identity: identity)
        let parts: [Substring] = identity.split(separator: ".", omittingEmptySubsequences: false)
        let kind: LiveKitGroupIdentityKind = try parseKind(prefix: parts[0])
        let peerDigits: Substring = parts[0].dropFirst()
        guard let peerId: Int64 = Int64(String(peerDigits)), peerId > 0 else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        return LiveKitGroupIdentity(
            kind: kind,
            peerId: peerId,
            source: UInt32(bitPattern: signedSource),
            isPresentation: parts.count == 3
        )
    }


    private static func parseKind(prefix: Substring) throws -> LiveKitGroupIdentityKind {
        guard let kindByte: UInt8 = prefix.utf8.first else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        switch kindByte {
        case 0x75:
            return .user

        case 0x63:
            return .chat

        case 0x68:
            return .channel

        default:
            throw LiveKitJoinParametersError.invalidIdentity
        }
    }
}
