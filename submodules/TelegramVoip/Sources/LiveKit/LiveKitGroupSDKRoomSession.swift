import Foundation
import LiveKit


/// Adapts the LiveKit room delegate to the group sink. LiveKit calls it on its own threads, so every event hops to the main actor.
/// The audio track events go to the hub, which registers each track on the calling thread and hops to the main actor itself.
private final class LiveKitGroupRoomDelegateBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private let sink: LiveKitGroupRoomEventSink
    private let audioTracks: LiveKitAudioTrackHub


    init(sink: LiveKitGroupRoomEventSink, audioTracks: LiveKitAudioTrackHub) {
        self.sink = sink
        self.audioTracks = audioTracks
        super.init()
    }


    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        let target: LiveKitGroupRoomEventSink = sink
        Task { @MainActor in
            target.roomDidFailToConnect()
        }
    }


    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let target: LiveKitGroupRoomEventSink = sink
        Task { @MainActor in
            target.roomDidDisconnectUnexpectedly()
        }
    }


    @objc(room:localParticipant:didPublishTrack:)
    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        guard publication.kind == .audio, let track: LocalAudioTrack = publication.track as? LocalAudioTrack else {
            return
        }
        let identity: String = participant.identity?.stringValue ?? ""
        audioTracks.trackDidAppear(key: publication.sid.stringValue) { () -> LiveKitAudioTrackHandle in
            return LiveKitAudioTrackHandleSDK(participantIdentity: identity, isLocal: true, track: track)
        }
    }


    @objc(room:localParticipant:didUnpublishTrack:)
    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        guard publication.kind == .audio else {
            return
        }
        audioTracks.trackDidGoAway(key: publication.sid.stringValue)
    }


    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio, let track: RemoteAudioTrack = publication.track as? RemoteAudioTrack else {
            return
        }
        let identity: String = participant.identity?.stringValue ?? ""
        audioTracks.trackDidAppear(key: publication.sid.stringValue) { () -> LiveKitAudioTrackHandle in
            return LiveKitAudioTrackHandleSDK(participantIdentity: identity, isLocal: false, track: track)
        }
    }


    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else {
            return
        }
        audioTracks.trackDidGoAway(key: publication.sid.stringValue)
    }


    @objc(room:remoteParticipant:didUnpublishTrack:)
    func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else {
            return
        }
        audioTracks.trackDidGoAway(key: publication.sid.stringValue)
    }
}


/// The production group room session: a LiveKit `Room` with default options and no end-to-end encryption.
/// Its media seam is the local participant of the same room, so the room itself never leaves this file.
final class LiveKitGroupSDKRoomSession: LiveKitGroupRoomSession {
    var media: LiveKitRoomMedia? {
        return roomMedia
    }


    var remoteParticipants: [LiveKitGroupRemoteParticipant] {
        return LiveKitGroupRemoteVideo.remoteParticipants(of: room)
    }


    private let bridge: LiveKitGroupRoomDelegateBridge
    private let room: Room
    private let roomMedia: LiveKitRoomMediaSDK


    init(
        sink: LiveKitGroupRoomEventSink,
        prioritizeVP8: Bool = false
    ) {
        let audioTracks: LiveKitAudioTrackHub = LiveKitAudioTrackHub()
        let roomBridge: LiveKitGroupRoomDelegateBridge = LiveKitGroupRoomDelegateBridge(sink: sink, audioTracks: audioTracks)
        let roomOptions: RoomOptions = RoomOptions()
        let roomInstance: Room = Room(
            delegate: roomBridge,
            connectOptions: nil,
            roomOptions: roomOptions
        )
        self.bridge = roomBridge
        self.room = roomInstance
        self.roomMedia = LiveKitRoomMediaSDK(
            localParticipant: roomInstance.localParticipant,
            isGroupCall: true,
            audioTracks: audioTracks,
            prioritizeVP8: prioritizeVP8
        )
    }


    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }


    func disconnect() async {
        await room.disconnect()
    }
}
