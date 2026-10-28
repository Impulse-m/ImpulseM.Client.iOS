import Foundation


/// The event names the client may report. A name outside this list is refused before anything is queued.
public enum ImpulseTelemetryEventName: String, CaseIterable, Sendable {
    case networkSummary = "network_telemetry_summary"
    case networkFailures = "network_telemetry_failures"
}


/// A telemetry field value. Only these three shapes are sent.
public enum ImpulseTelemetryValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
}


/// One queued `help.saveAppLog` event, with the app name already in its fields.
public struct ImpulseTelemetryEvent: Equatable, Sendable {
    public let name: ImpulseTelemetryEventName
    public let time: Double
    public let fields: [String: ImpulseTelemetryValue]


    init(
        name: ImpulseTelemetryEventName,
        time: Double,
        fields: [String: ImpulseTelemetryValue]
    ) {
        self.name = name
        self.time = time
        self.fields = fields
    }
}


/// Why a telemetry event was refused. A refused event is never queued and never sent.
public enum ImpulseTelemetryError: Error, Equatable, Sendable {
    case unknownEventName(String)
    case invalidFieldName(String)
    case invalidFieldValue(String)
    case secretField(String)
}


/// Carries a batch of events to the backend. The request is a serialised `help.saveAppLog` TL call.
public protocol ImpulseTelemetrySink: Sendable {
    func saveAppLog(request: [UInt8]) async throws
}


/// The constants and the TL encoder of the `help.saveAppLog` batch.
public enum ImpulseTelemetryEncoding {
    /// The app name sent with every event. The backend may refuse it; the refusal is accepted.
    public static let appName: String = "ImpulseM.Mac"
    /// The field that carries the app name.
    public static let appNameField: String = "app_name"

    private static let saveAppLogId: UInt32 = 0x6f02f748
    private static let inputAppEventId: UInt32 = 0x1d1b1245
    private static let jsonObjectId: UInt32 = 0x99c1d49d
    private static let jsonObjectValueId: UInt32 = 0xc0de1bd9
    private static let jsonStringId: UInt32 = 0xb71e767a
    private static let jsonNumberId: UInt32 = 0x2be0dfa4
    private static let jsonBoolId: UInt32 = 0xc7345e6a


    /// Serialises `help.saveAppLog(events:)`. Fields are written in key order so the bytes are stable.
    public static func saveAppLogRequest(events: [ImpulseTelemetryEvent]) throws -> [UInt8] {
        var writer: ImpulseTlWriter = ImpulseTlWriter()
        writer.writeInt32(value: bitPattern(saveAppLogId))
        writer.writeInt32(value: bitPattern(ImpulseTlConstants.vector))
        writer.writeInt32(value: Int32(events.count))

        for event: ImpulseTelemetryEvent in events {
            try writeEvent(event, writer: &writer)
        }

        return writer.toByteArray()
    }


    private static func writeEvent(
        _ event: ImpulseTelemetryEvent,
        writer: inout ImpulseTlWriter
    ) throws {
        writer.writeInt32(value: bitPattern(inputAppEventId))
        writer.writeDouble(value: event.time)
        try writer.writeString(value: event.name.rawValue)
        writer.writeInt64(value: 0)
        try writeJSONObject(event.fields, writer: &writer)
    }


    private static func writeJSONObject(
        _ fields: [String: ImpulseTelemetryValue],
        writer: inout ImpulseTlWriter
    ) throws {
        writer.writeInt32(value: bitPattern(jsonObjectId))
        writer.writeInt32(value: bitPattern(ImpulseTlConstants.vector))
        writer.writeInt32(value: Int32(fields.count))

        for key: String in fields.keys.sorted() {
            guard let value: ImpulseTelemetryValue = fields[key] else {
                continue
            }

            writer.writeInt32(value: bitPattern(jsonObjectValueId))
            try writer.writeString(value: key)
            try writeJSONValue(value, writer: &writer)
        }
    }


    private static func writeJSONValue(
        _ value: ImpulseTelemetryValue,
        writer: inout ImpulseTlWriter
    ) throws {
        switch value {
        case .bool(let flag):
            writer.writeInt32(value: bitPattern(jsonBoolId))
            writer.writeInt32(value: bitPattern(flag ? ImpulseTlConstants.boolTrue : ImpulseTlConstants.boolFalse))

        case .number(let number):
            writer.writeInt32(value: bitPattern(jsonNumberId))
            writer.writeDouble(value: number)

        case .string(let text):
            writer.writeInt32(value: bitPattern(jsonStringId))
            try writer.writeString(value: text)
        }
    }


    private static func bitPattern(_ value: UInt32) -> Int32 {
        return Int32(bitPattern: value)
    }
}


/// Queues telemetry events and sends them in batches through `help.saveAppLog`.
///
/// Events are held in memory only until the next flush. A batch that fails to send is dropped, not retried and not
/// written anywhere else.
public actor ImpulseTelemetry {
    public static let maxStringBytes: Int = 512
    public static let maxFieldNameLength: Int = 64

    private static let secretNameFragments: [String] = [
        "token",
        "secret",
        "password",
        "passwd",
        "credential",
        "auth",
        "session",
        "identity",
        "hash",
        "key",
        "cookie",
        "bearer",
    ]

    private let sink: any ImpulseTelemetrySink
    private let batchLimit: Int
    private let clock: @Sendable () -> Double
    private var pending: [ImpulseTelemetryEvent] = []


    public init(
        sink: any ImpulseTelemetrySink,
        maxBatchSize: Int = 50,
        clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.sink = sink
        self.batchLimit = max(1, maxBatchSize)
        self.clock = clock
    }


    /// The number of events waiting for the next flush.
    public var pendingCount: Int {
        return pending.count
    }


    /// Queues one event. A name outside `ImpulseTelemetryEventName`, a field name or value that is not allowed, and any
    /// secret-looking field are refused and nothing is queued. Reaching the batch size sends a flush.
    public func record(name: String, fields: [String: ImpulseTelemetryValue]) async throws {
        guard let eventName: ImpulseTelemetryEventName = ImpulseTelemetryEventName(rawValue: name) else {
            throw ImpulseTelemetryError.unknownEventName(name)
        }

        try ImpulseTelemetry.validate(fields: fields)

        var data: [String: ImpulseTelemetryValue] = fields
        data[ImpulseTelemetryEncoding.appNameField] = .string(ImpulseTelemetryEncoding.appName)
        pending.append(ImpulseTelemetryEvent(name: eventName, time: clock(), fields: data))

        if pending.count >= batchLimit {
            await flush()
        }
    }


    /// Sends everything queued, in batches of at most the batch size. The queue is emptied first; a failed batch is
    /// dropped.
    public func flush() async {
        let events: [ImpulseTelemetryEvent] = pending
        pending = []

        var start: Int = 0
        while start < events.count {
            let end: Int = min(start + batchLimit, events.count)
            let batch: [ImpulseTelemetryEvent] = Array(events[start ..< end])
            start = end

            guard let request: [UInt8] = try? ImpulseTelemetryEncoding.saveAppLogRequest(events: batch) else {
                continue
            }

            do {
                try await sink.saveAppLog(request: request)
            } catch {
                continue
            }
        }
    }


    private static func validate(fields: [String: ImpulseTelemetryValue]) throws {
        for key: String in fields.keys.sorted() {
            guard isValidFieldName(key) else {
                throw ImpulseTelemetryError.invalidFieldName(key)
            }

            if isSecretName(key) {
                throw ImpulseTelemetryError.secretField(key)
            }

            guard let value: ImpulseTelemetryValue = fields[key] else {
                continue
            }

            switch value {
            case .bool:
                break

            case .number(let number):
                guard number.isFinite else {
                    throw ImpulseTelemetryError.invalidFieldValue(key)
                }

            case .string(let text):
                guard text.utf8.count <= maxStringBytes else {
                    throw ImpulseTelemetryError.invalidFieldValue(key)
                }

                if isSecretValue(text) {
                    throw ImpulseTelemetryError.secretField(key)
                }
            }
        }
    }


    private static func isValidFieldName(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= maxFieldNameLength else {
            return false
        }

        for scalar: Unicode.Scalar in key.unicodeScalars {
            let isLowerLetter: Bool = scalar.value >= 0x61 && scalar.value <= 0x7A
            let isDigit: Bool = scalar.value >= 0x30 && scalar.value <= 0x39
            let isUnderscore: Bool = scalar.value == 0x5F

            if !isLowerLetter && !isDigit && !isUnderscore {
                return false
            }
        }

        return true
    }


    private static func isSecretName(_ key: String) -> Bool {
        let lowered: String = key.lowercased()

        for fragment: String in secretNameFragments where lowered.contains(fragment) {
            return true
        }

        return false
    }


    private static func isSecretValue(_ text: String) -> Bool {
        if text.hasPrefix("eyJ") {
            return true
        }

        return text.lowercased().contains("bearer ")
    }
}
