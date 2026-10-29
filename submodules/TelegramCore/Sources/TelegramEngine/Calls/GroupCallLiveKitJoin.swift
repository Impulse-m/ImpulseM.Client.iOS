import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi


/// The LiveKit join parameters of a group connection: the server URL and the room name. The token is checked for presence only and is never stored.
struct GroupCallLiveKitJoinParameters: Equatable {
    let url: String
    let room: String
}


enum GroupCallLiveKitJoinParser {
    /// Parses `{"livekit":{"url":...,"token":...,"room":...}}` for a group call. The room must be `g.<callId>`, the URL must be `ws` or `wss` with a host.
    /// Any failure returns nil, and the parser error is dropped on purpose, because the input can contain the bearer token.
    static func parse(json: String, callId: Int64) -> GroupCallLiveKitJoinParameters? {
        guard callId > 0 else {
            return nil
        }
        guard let data: Data = json.data(using: .utf8) else {
            return nil
        }
        guard let object: Any = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        guard let root: [String: Any] = object as? [String: Any] else {
            return nil
        }
        guard let livekit: [String: Any] = root["livekit"] as? [String: Any] else {
            return nil
        }
        guard let url: String = nonBlankString(livekit["url"]) else {
            return nil
        }
        guard nonBlankString(livekit["token"]) != nil else {
            return nil
        }
        guard let room: String = nonBlankString(livekit["room"]) else {
            return nil
        }
        guard room == "g.\(callId)" else {
            return nil
        }
        guard isValidServerUrl(url) else {
            return nil
        }
        return GroupCallLiveKitJoinParameters(url: url, room: room)
    }


    /// The join answer of a presentation (screencast) connection. The LiveKit parameters are validated and returned unchanged.
    /// The endpoint of the own presentation is read from the participant list of the answer, when the answer carries it.
    static func screencastJoinResult(
        callId: Int64,
        selfPeerId: PeerId,
        updates: Api.Updates
    ) -> Signal<JoinGroupCallAsScreencastResult, JoinGroupCallError> {
        guard let params: String = connectionParams(updates: updates) else {
            return .fail(.generic)
        }
        guard parse(json: params, callId: callId) != nil else {
            return .fail(.generic)
        }
        let endpointId: String? = selfPresentationEndpoint(updates: updates, selfPeerId: selfPeerId)
        return .single(JoinGroupCallAsScreencastResult(
            jsonParams: params,
            endpointId: endpointId
        ))
    }


    private static func connectionParams(updates: Api.Updates) -> String? {
        var params: String?
        for update in updates.allUpdates {
            guard case let .updateGroupCallConnection(connectionData) = update else {
                continue
            }
            switch connectionData.params {
            case let .dataJSON(dataJSONData):
                params = dataJSONData.data
            }
        }
        return params
    }


    private static func selfPresentationEndpoint(updates: Api.Updates, selfPeerId: PeerId) -> String? {
        for update in updates.allUpdates {
            guard case let .updateGroupCallParticipants(participantsData) = update else {
                continue
            }
            for participant in participantsData.participants {
                guard case let .groupCallParticipant(participantData) = participant else {
                    continue
                }
                guard participantData.peer.peerId == selfPeerId else {
                    continue
                }
                guard let presentation: Api.GroupCallParticipantVideo = participantData.presentation else {
                    return nil
                }
                guard case let .groupCallParticipantVideo(videoData) = presentation else {
                    return nil
                }
                let endpoint: String = videoData.endpoint
                return endpoint.isEmpty ? nil : endpoint
            }
        }
        return nil
    }


    /// A string value that is not blank. Blank means only scalars up to U+0020.
    private static func nonBlankString(_ value: Any?) -> String? {
        guard let string: String = value as? String else {
            return nil
        }
        let isBlank: Bool = string.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            return scalar.value <= 0x20
        }
        if isBlank {
            return nil
        }
        return string
    }


    /// Accepts `ws` or `wss` URLs with a host, no userinfo, no fragment and no control or space characters.
    private static func isValidServerUrl(_ url: String) -> Bool {
        let hasForbiddenCharacter: Bool = url.unicodeScalars.contains { (scalar: Unicode.Scalar) -> Bool in
            return scalar.value <= 0x20 || scalar.value == 0x7f
        }
        if hasForbiddenCharacter {
            return false
        }
        guard let components: URLComponents = URLComponents(string: url) else {
            return false
        }
        guard let scheme: String = components.scheme, scheme == "wss" || scheme == "ws" else {
            return false
        }
        guard let host: String = components.host, !host.isEmpty else {
            return false
        }
        if components.user != nil || components.password != nil {
            return false
        }
        if components.fragment != nil {
            return false
        }
        return true
    }
}
