import Foundation
import LiveKit


/// Adapts the LiveKit room delegate to the group sink. LiveKit calls it on its own threads, so every event hops to the main actor.
private final class LiveKitGroupRoomDelegateBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private let sink: LiveKitGroupRoomEventSink


    init(sink: LiveKitGroupRoomEventSink) {
        self.sink = sink
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
}


/// The production group room session: a LiveKit `Room` with default options and no end-to-end encryption.
/// Its media seam is the local participant of the same room, so the room itself never leaves this file.
final class LiveKitGroupSDKRoomSession: LiveKitGroupRoomSession {
    var media: LiveKitRoomMedia? {
        return roomMedia
    }


    private let bridge: LiveKitGroupRoomDelegateBridge
    private let room: Room
    private let roomMedia: LiveKitRoomMediaSDK


    init(sink: LiveKitGroupRoomEventSink) {
        let roomBridge: LiveKitGroupRoomDelegateBridge = LiveKitGroupRoomDelegateBridge(sink: sink)
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
            isGroupCall: true
        )
    }


    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }


    func disconnect() async {
        await room.disconnect()
    }
}
