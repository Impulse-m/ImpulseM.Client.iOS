import Foundation


/// The join parameters of a LiveKit room: the server URL, the bearer token and the room name.
///
/// The token is a bearer secret. The description of this type never prints it.
public struct LiveKitJoinParameters: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: String
    public let token: String
    public let room: String


    public init(url: String, token: String, room: String) {
        self.url = url
        self.token = token
        self.room = room
    }


    public var description: String {
        return "LiveKitJoinParameters(url: \(url), token: <redacted>, room: \(room))"
    }


    public var debugDescription: String {
        return description
    }


    /// Parses `{"livekit":{"url":...,"token":...,"room":...}}` and validates it for the call.
    ///
    /// Every failure throws `LiveKitJoinParametersError`. The parser error is dropped on purpose, because it can contain the token.
    public static func parse(
        json: String,
        isGroup: Bool,
        callId: Int64
    ) throws -> LiveKitJoinParameters {
        guard let root: [String: Any] = try? parseObject(json: json) else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard let livekit: [String: Any] = root["livekit"] as? [String: Any] else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard let url: String = requiredString(object: livekit, name: "url") else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard let token: String = requiredString(object: livekit, name: "token") else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard let room: String = requiredString(object: livekit, name: "room") else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard isValidServerUrl(url) else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        guard callId > 0 else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        let expectedRoom: String = (isGroup ? "g." : "p.") + String(callId)
        guard room == expectedRoom else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        return LiveKitJoinParameters(url: url, token: token, room: room)
    }


    private static func parseObject(json: String) throws -> [String: Any] {
        let object: Any = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
        guard let dictionary: [String: Any] = object as? [String: Any] else {
            throw LiveKitJoinParametersError.invalidJoinParameters
        }
        return dictionary
    }


    /// A string value that is not blank. Blank means only scalars up to U+0020, the same rule as Java `String.trim()`.
    private static func requiredString(
        object: [String: Any],
        name: String
    ) -> String? {
        guard let value: String = object[name] as? String else {
            return nil
        }
        let isBlank: Bool = value.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            return scalar.value <= 0x20
        }
        if isBlank {
            return nil
        }
        return value
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


public enum LiveKitJoinParametersError: Error, LocalizedError, Equatable {
    case invalidJoinParameters
    case invalidIdentity


    public var errorDescription: String? {
        switch self {
        case .invalidJoinParameters:
            return "Invalid LiveKit join parameters for this call"

        case .invalidIdentity:
            return "Invalid LiveKit group identity"
        }
    }
}


/// Participant identities of LiveKit group calls, in the form `<k><peerId>.<source>` with an optional `.p` suffix.
public enum LiveKitIdentity {
    /// Returns the SSRC of an identity. The source is an unsigned 32-bit value, cast to a signed 32-bit value with the same bits.
    public static func groupSource(identity: String) throws -> Int32 {
        let parts: [Substring] = identity.split(separator: ".", omittingEmptySubsequences: false)
        let hasPresentationSuffix: Bool = parts.count == 3 && parts[2] == "p"
        guard parts.count == 2 || hasPresentationSuffix else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        let prefix: Substring = parts[0]
        guard let kind: UInt8 = prefix.utf8.first, kind == 0x75 || kind == 0x63 || kind == 0x68 else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        guard isCanonicalDecimal(prefix.dropFirst()) else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        guard isCanonicalDecimal(parts[1]) else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        guard let source: UInt64 = UInt64(parts[1]), source <= 0xffffffff else {
            throw LiveKitJoinParametersError.invalidIdentity
        }
        return Int32(bitPattern: UInt32(source))
    }


    /// A non-empty run of ASCII digits with no leading zero.
    private static func isCanonicalDecimal(_ digits: Substring) -> Bool {
        guard let first: UInt8 = digits.utf8.first, first != 0x30 else {
            return false
        }
        return digits.utf8.allSatisfy { (byte: UInt8) -> Bool in
            return byte >= 0x30 && byte <= 0x39
        }
    }
}
