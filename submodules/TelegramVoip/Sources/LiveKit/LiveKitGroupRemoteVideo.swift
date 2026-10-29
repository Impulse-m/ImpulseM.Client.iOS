import Foundation
import LiveKit


/// The quality of a remote group video channel, as the group call UI requests it.
public enum LiveKitGroupVideoQuality: Equatable {
    case low
    case medium
    case high
}


/// One requested remote video channel: the endpoint (`<k><peer>.<source>`, with a `.p` suffix for a presentation), the quality, and whether the channel is visible.
public struct LiveKitGroupVideoRequest: Equatable {
    public let endpoint: String
    public let quality: LiveKitGroupVideoQuality
    public let isVisible: Bool


    public init(
        endpoint: String,
        quality: LiveKitGroupVideoQuality,
        isVisible: Bool
    ) {
        self.endpoint = endpoint
        self.quality = quality
        self.isVisible = isVisible
    }
}


/// A remote video track of a group participant. The SDK track sits behind this seam, so tests can use fakes.
public protocol LiveKitGroupRemoteVideoTrack: AnyObject {
    /// The SDK track behind this value, or nil when the value is not backed by one.
    var sdkTrack: RemoteVideoTrack? { get }
}


/// A video publication of a remote group participant, with the two controls that the group call uses.
public protocol LiveKitGroupRemotePublication: AnyObject {
    /// The subscribed video track, or nil while the publication has no track.
    var videoTrack: LiveKitGroupRemoteVideoTrack? { get }

    /// Enables or disables the server from sending the video of this publication.
    func setEnabled(_ isEnabled: Bool) async throws

    /// Sets the highest quality that the client accepts for this publication.
    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws
}


/// A remote participant of the main group room. Its identity is the video endpoint of the participant.
public protocol LiveKitGroupRemoteParticipant: AnyObject {
    /// The LiveKit identity, or nil while the SDK has no identity for the participant.
    var identity: String? { get }

    /// The video publications of the participant, in a stable order.
    var videoPublications: [LiveKitGroupRemotePublication] { get }
}


/// Finds the remote video tracks of the main group room by endpoint and applies the channel requests of the group call.
public final class LiveKitGroupRemoteVideo {
    private let remoteParticipants: () -> [LiveKitGroupRemoteParticipant]


    public init(remoteParticipants: @escaping () -> [LiveKitGroupRemoteParticipant]) {
        self.remoteParticipants = remoteParticipants
    }


    /// The video track of the room participant whose identity is the endpoint. A presentation endpoint ends in `.p` and is matched as it is.
    /// Returns nil when no participant owns the endpoint, or when the participant has no video track yet.
    public func videoTrack(endpoint: String) -> LiveKitGroupRemoteVideoTrack? {
        for participant: LiveKitGroupRemoteParticipant in remoteParticipants() where participant.identity == endpoint {
            for publication: LiveKitGroupRemotePublication in participant.videoPublications {
                if let track: LiveKitGroupRemoteVideoTrack = publication.videoTrack {
                    return track
                }
            }
            return nil
        }
        return nil
    }


    /// Applies the channel requests to the video publications of the room. A publication whose endpoint is requested as visible is enabled and gets the requested quality.
    /// Every other publication is disabled. A request for an endpoint that the room does not have changes nothing, and a participant without an identity is not touched.
    /// Every publication is applied even when one fails; the first failure is thrown after all of them.
    public func applyRequests(_ requests: [LiveKitGroupVideoRequest]) async throws {
        var requestsByEndpoint: [String: LiveKitGroupVideoRequest] = [:]
        for request: LiveKitGroupVideoRequest in requests {
            if requestsByEndpoint[request.endpoint] == nil {
                requestsByEndpoint[request.endpoint] = request
            }
        }
        var firstError: Error?
        for participant: LiveKitGroupRemoteParticipant in remoteParticipants() {
            guard let endpoint: String = participant.identity else {
                continue
            }
            let request: LiveKitGroupVideoRequest? = requestsByEndpoint[endpoint]
            for publication: LiveKitGroupRemotePublication in participant.videoPublications {
                do {
                    try await apply(
                        request: request,
                        to: publication
                    )
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }
        if let error: Error = firstError {
            throw error
        }
    }


    private func apply(
        request: LiveKitGroupVideoRequest?,
        to publication: LiveKitGroupRemotePublication
    ) async throws {
        guard let request: LiveKitGroupVideoRequest = request, request.isVisible else {
            try await publication.setEnabled(false)
            return
        }
        try await publication.setEnabled(true)
        try await publication.setVideoQuality(request.quality)
    }
}


extension LiveKitGroupRemoteVideo {
    /// Reads the remote participants of a LiveKit room, so the endpoints are looked up in that room.
    public convenience init(room: Room) {
        self.init(remoteParticipants: {
            return room.remoteParticipants.values.map { (participant: RemoteParticipant) -> LiveKitGroupRemoteParticipant in
                return LiveKitGroupSDKRemoteParticipant(participant: participant)
            }
        })
    }
}


extension RemoteVideoTrack: LiveKitGroupRemoteVideoTrack {
    public var sdkTrack: RemoteVideoTrack? {
        return self
    }
}


private extension LiveKitGroupVideoQuality {
    var sdkQuality: VideoQuality {
        switch self {
        case .low:
            return .low

        case .medium:
            return .medium

        case .high:
            return .high
        }
    }
}


/// Wraps a LiveKit remote participant. Its publications are read when they are asked for, so the wrapper always shows the room state.
private final class LiveKitGroupSDKRemoteParticipant: LiveKitGroupRemoteParticipant {
    private let participant: RemoteParticipant


    init(participant: RemoteParticipant) {
        self.participant = participant
    }


    var identity: String? {
        return participant.identity?.stringValue
    }


    var videoPublications: [LiveKitGroupRemotePublication] {
        let remotePublications: [RemoteTrackPublication] = participant.trackPublications.values.compactMap { (publication: TrackPublication) -> RemoteTrackPublication? in
            guard publication.kind == .video else {
                return nil
            }
            return publication as? RemoteTrackPublication
        }
        let sortedPublications: [RemoteTrackPublication] = remotePublications.sorted { (first: RemoteTrackPublication, second: RemoteTrackPublication) -> Bool in
            return first.sid.stringValue < second.sid.stringValue
        }
        return sortedPublications.map { (publication: RemoteTrackPublication) -> LiveKitGroupRemotePublication in
            return LiveKitGroupSDKRemotePublication(publication: publication)
        }
    }
}


/// Wraps a LiveKit remote video publication with the two group controls.
private final class LiveKitGroupSDKRemotePublication: LiveKitGroupRemotePublication {
    private let publication: RemoteTrackPublication


    init(publication: RemoteTrackPublication) {
        self.publication = publication
    }


    var videoTrack: LiveKitGroupRemoteVideoTrack? {
        return publication.track as? RemoteVideoTrack
    }


    func setEnabled(_ isEnabled: Bool) async throws {
        try await publication.set(enabled: isEnabled)
    }


    func setVideoQuality(_ quality: LiveKitGroupVideoQuality) async throws {
        try await publication.set(videoQuality: quality.sdkQuality)
    }
}
