import Foundation
import LiveKit


/// The remote media of a private call: the remote video publication to render and whether any remote audio is active.
public struct LiveKitPrivateRemoteMedia {
    /// The chosen remote video publication, or nil when no participant has video to show.
    public let publication: LiveKitGroupRemotePublication?

    /// True when a remote participant has a subscribed, unmuted audio publication.
    public let isAudioActive: Bool


    public var isVideoActive: Bool {
        return publication != nil
    }


    public var videoTrack: RemoteVideoTrack? {
        return publication?.videoTrack?.sdkTrack
    }


    /// No remote video and no remote audio.
    public static let none: LiveKitPrivateRemoteMedia = LiveKitPrivateRemoteMedia(publication: nil, isAudioActive: false)


    /// Chooses the remote video of the participants: the first screen share, else the first camera, else the first other source.
    /// Only publications with a track that is not muted are candidates. The audio is active when any participant has active audio.
    public static func resolve(_ participants: [LiveKitGroupRemoteParticipant]) -> LiveKitPrivateRemoteMedia {
        var candidates: [LiveKitGroupRemotePublication] = []
        for participant: LiveKitGroupRemoteParticipant in participants {
            for publication: LiveKitGroupRemotePublication in participant.videoPublications {
                guard publication.videoTrack != nil, !publication.isMuted else {
                    continue
                }
                candidates.append(publication)
            }
        }
        let chosen: LiveKitGroupRemotePublication? = firstPublication(
            in: candidates,
            source: .screenShare
        ) ?? firstPublication(
            in: candidates,
            source: .camera
        ) ?? firstPublication(
            in: candidates,
            source: .other
        )
        let isAudioActive: Bool = participants.contains { (participant: LiveKitGroupRemoteParticipant) -> Bool in
            return participant.isAudioActive
        }
        return LiveKitPrivateRemoteMedia(publication: chosen, isAudioActive: isAudioActive)
    }


    private static func firstPublication(
        in candidates: [LiveKitGroupRemotePublication],
        source: LiveKitRemoteVideoSource
    ) -> LiveKitGroupRemotePublication? {
        return candidates.first { (publication: LiveKitGroupRemotePublication) -> Bool in
            return publication.source == source
        }
    }
}
