import Foundation

public enum ImpulseEnvelopeParseResult: Equatable, Sendable {
    case envelope(ImpulseEnvelope)
    case legacySessionRevoked
    case undecodable
}


public struct ImpulseEnvelope: Equatable, Sendable {

    public let type: Int
    public let pts: Int64
    public let ptsCount: Int
    public let date: Int
    public let body: Data


    public init(
        type: Int,
        pts: Int64,
        ptsCount: Int,
        date: Int,
        body: Data
    ) {
        self.type = type
        self.pts = pts
        self.ptsCount = ptsCount
        self.date = date
        self.body = body
    }


    public static func ptsLess(type: Int, date: Int, body: Data) -> ImpulseEnvelope {
        return ImpulseEnvelope(type: type, pts: 0, ptsCount: 0, date: date, body: body)
    }


    public static func numbered(
        type: Int,
        pts: Int64,
        ptsCount: Int,
        date: Int,
        body: Data
    ) -> ImpulseEnvelope {
        return ImpulseEnvelope(type: type, pts: pts, ptsCount: ptsCount, date: date, body: body)
    }


    public static func unnumbered(type: Int, date: Int, body: Data) -> ImpulseEnvelope {
        return ImpulseEnvelope(type: type, pts: 0, ptsCount: 0, date: date, body: body)
    }


    /// The body is the encoded update container that carries the `updatesTooLong` update.
    public static func updatesTooLong(type: Int, date: Int, body: Data) -> ImpulseEnvelope {
        return ImpulseEnvelope(type: type, pts: 0, ptsCount: 0, date: date, body: body)
    }


    /// Reads the raw data of a publication. Never throws: anything that does not satisfy the envelope
    /// rules yields `.undecodable`, and the caller is expected to run a difference fetch.
    public static func parse(bytes: Data?) -> ImpulseEnvelopeParseResult {
        guard let data: Data = bytes else {
            return .undecodable
        }
        guard let root: ImpulseEnvelopeJSONValue = try? JSONDecoder().decode(ImpulseEnvelopeJSONValue.self, from: data) else {
            return .undecodable
        }
        switch root {
        case .array(let elements):
            return isLegacySessionRevokedArray(elements) ? .legacySessionRevoked : .undecodable
        case .object(let fields):
            return parseObject(fields)
        default:
            return .undecodable
        }
    }


    /// Serializes the envelope as the JSON object the server publishes. `pts` and `ptsCount` are omitted
    /// when both are zero, which is how pts-less frames are sent.
    public func jsonData() throws -> Data {
        var object: [String: Any] = [
            "type": type,
            "date": date,
            "data": body.base64EncodedString(),
        ]
        if pts != 0 || ptsCount != 0 {
            object["pts"] = pts
            object["ptsCount"] = ptsCount
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }


    private static func parseObject(_ fields: [String: ImpulseEnvelopeJSONValue]) -> ImpulseEnvelopeParseResult {
        guard case .string(let encodedBody)? = fields["data"] else {
            return .undecodable
        }
        guard let body: Data = decodeBase64(encodedBody), !body.isEmpty else {
            return .undecodable
        }
        guard
            let type: Int = positiveField(fields, name: "type"),
            let date: Int = positiveField(fields, name: "date"),
            let pts: Int64 = integerField(fields, name: "pts"),
            let ptsCount: Int = intField(fields, name: "ptsCount")
        else {
            return .undecodable
        }
        return .envelope(ImpulseEnvelope(type: type, pts: pts, ptsCount: ptsCount, date: date, body: body))
    }


    private static func isLegacySessionRevokedArray(_ elements: [ImpulseEnvelopeJSONValue]) -> Bool {
        guard !elements.isEmpty else {
            return false
        }
        return elements.allSatisfy { (element: ImpulseEnvelopeJSONValue) -> Bool in
            guard case .object(let fields) = element, case .string(let eventType)? = fields["event_type"] else {
                return false
            }
            return eventType == "session.revoked"
        }
    }


    /// A missing or null field reads as 0. Numbers and numeric strings are accepted; anything else is invalid.
    private static func integerField(_ fields: [String: ImpulseEnvelopeJSONValue], name: String) -> Int64? {
        guard let value: ImpulseEnvelopeJSONValue = fields[name] else {
            return 0
        }
        switch value {
        case .null:
            return 0
        case .int(let integer):
            return integer
        case .double(let number):
            return Int64(exactly: number)
        case .string(let text):
            return Int64(text)
        default:
            return nil
        }
    }


    private static func intField(_ fields: [String: ImpulseEnvelopeJSONValue], name: String) -> Int? {
        guard let integer: Int64 = integerField(fields, name: name), let number: Int = Int(exactly: integer) else {
            return nil
        }
        return number
    }


    private static func positiveField(_ fields: [String: ImpulseEnvelopeJSONValue], name: String) -> Int? {
        guard let number: Int = intField(fields, name: name), number > 0 else {
            return nil
        }
        return number
    }


    /// Accepts both the standard and the URL-safe alphabet, ignores whitespace and padding, and rejects anything else.
    private static func decodeBase64(_ text: String) -> Data? {
        let alphabet: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var normalized: String = ""
        for scalar: Unicode.Scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}":
                continue
            case "-":
                normalized.append("+")
            case "_":
                normalized.append("/")
            default:
                normalized.unicodeScalars.append(scalar)
            }
        }
        while normalized.hasSuffix("=") {
            normalized.removeLast()
        }
        let isValidAlphabet: Bool = normalized.allSatisfy { (character: Character) -> Bool in
            return alphabet.contains(character)
        }
        guard isValidAlphabet else {
            return nil
        }
        let remainder: Int = normalized.count % 4
        if remainder == 1 {
            return nil
        }
        if remainder == 2 {
            normalized.append("==")
        } else if remainder == 3 {
            normalized.append("=")
        }
        return Data(base64Encoded: normalized)
    }
}


fileprivate enum ImpulseEnvelopeJSONValue: Decodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ImpulseEnvelopeJSONValue])
    case object([String: ImpulseEnvelopeJSONValue])


    fileprivate init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag: Bool = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let integer: Int64 = try? container.decode(Int64.self) {
            self = .int(integer)
        } else if let number: Double = try? container.decode(Double.self) {
            self = .double(number)
        } else if let text: String = try? container.decode(String.self) {
            self = .string(text)
        } else if let elements: [ImpulseEnvelopeJSONValue] = try? container.decode([ImpulseEnvelopeJSONValue].self) {
            self = .array(elements)
        } else if let fields: [String: ImpulseEnvelopeJSONValue] = try? container.decode([String: ImpulseEnvelopeJSONValue].self) {
            self = .object(fields)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}
