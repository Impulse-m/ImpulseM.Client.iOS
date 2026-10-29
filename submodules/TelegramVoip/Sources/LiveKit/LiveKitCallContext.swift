import Foundation
import LiveKit


/// Errors raised while a 1:1 LiveKit call context is created.
public enum LiveKitCallContextError: Error, LocalizedError, Equatable {
    case unsupportedProtocol
    case invalidAuthKey


    public var errorDescription: String? {
        switch self {
        case .unsupportedProtocol:
            return "Unsupported call protocol"

        case .invalidAuthKey:
            return "Call DH key must contain exactly 256 bytes"
        }
    }
}


/// Why a 1:1 LiveKit call ended.
public enum LiveKitCallEndReason: Equatable {
    case hungUp
    case joinTimedOut
    case connectionFailed
    case disconnected
    case mediaEncryptionFailed
}


/// The state of a 1:1 LiveKit call context.
public enum LiveKitCallState: Equatable {
    case connecting
    case connected
    case ended(LiveKitCallEndReason)
}


/// The room operations the call context drives. The production implementation wraps the LiveKit `Room`.
protocol LiveKitRoomSession: AnyObject {
    func connect(url: String, token: String) async throws
    func disconnect() async
}


/// Events that a room session reports back to the call context.
@MainActor
protocol LiveKitRoomEventSink: AnyObject {
    func roomDidFailToConnect()
    func roomDidDisconnectUnexpectedly()
    func roomDidReportMediaEncryption(_ encryptionState: LiveKitMediaEncryptionState)
}


/// Creates the room session of a call from the shared call key provider and the sink that receives its events.
typealias LiveKitRoomSessionFactory = (BaseKeyProvider, LiveKitRoomEventSink) -> LiveKitRoomSession


/// The encryption state of a media track as the call context sees it.
enum LiveKitMediaEncryptionState: Equatable {
    case healthy
    case failed
}


extension LiveKitMediaEncryptionState {
    /// `new`, `ok` and `key_ratcheted` are healthy. Missing key, encryption and decryption failures and internal errors fail the call.
    init(e2eeState: E2EEState) {
        switch e2eeState {
        case .new, .ok, .key_ratcheted:
            self = .healthy

        case .missing_key, .encryption_failed, .decryption_failed, .internal_error:
            self = .failed
        }
    }
}


/// The 1:1 call engine on LiveKit. It joins the room of the call with the shared call key and ends the call on failure.
///
/// The join deadline and the leave deadline bound the call: a join that does not finish in time ends the call, and a leave
/// that does not return in time reports the end anyway, so the call never waits forever.
@MainActor
public final class LiveKitCallContext: LiveKitRoomEventSink {
    /// The only call protocol offered and accepted for 1:1 LiveKit calls.
    public static let protocolName: String = "impulsem-livekit-1"

    /// Seconds allowed for the join after the call is accepted: 30 seconds plus 5 seconds of slack.
    public static let joinDeadlineSeconds: TimeInterval = 35

    /// Seconds allowed for the leave after a stop: 10 seconds plus 5 seconds of slack.
    public static let leaveDeadlineSeconds: TimeInterval = 15

    public private(set) var state: LiveKitCallState = .connecting
    public var onStateChanged: ((LiveKitCallState) -> Void)?

    private let parameters: LiveKitJoinParameters
    private let keyProvider: BaseKeyProvider
    private let joinDeadline: TimeInterval
    private let leaveDeadline: TimeInterval
    private let makeSession: LiveKitRoomSessionFactory
    private var session: LiveKitRoomSession?
    private var hasStarted: Bool = false
    private var isTerminating: Bool = false
    private var connectTask: Task<Void, Never>?
    private var joinTimerTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var leaveTimerTask: Task<Void, Never>?


    public convenience init(
        callId: Int64,
        versions: [String],
        parameters: String,
        authKey: Data
    ) throws {
        try self.init(
            callId: callId,
            versions: versions,
            parameters: parameters,
            authKey: authKey,
            joinDeadline: LiveKitCallContext.joinDeadlineSeconds,
            leaveDeadline: LiveKitCallContext.leaveDeadlineSeconds,
            makeSession: LiveKitCallContext.makeSDKSession
        )
    }


    init(
        callId: Int64,
        versions: [String],
        parameters: String,
        authKey: Data,
        joinDeadline: TimeInterval,
        leaveDeadline: TimeInterval,
        makeSession: @escaping LiveKitRoomSessionFactory
    ) throws {
        guard versions.contains(LiveKitCallContext.protocolName) else {
            throw LiveKitCallContextError.unsupportedProtocol
        }
        self.parameters = try LiveKitJoinParameters.parse(
            json: parameters,
            isGroup: false,
            callId: callId
        )
        self.keyProvider = try LiveKitCallContext.makeKeyProvider(authKey: authKey)
        self.joinDeadline = joinDeadline
        self.leaveDeadline = leaveDeadline
        self.makeSession = makeSession
    }


    /// Connects the room. Set `onStateChanged` before calling this. The call starts only once.
    public func start() {
        guard !hasStarted, !isTerminating else {
            return
        }
        hasStarted = true
        let roomSession: LiveKitRoomSession = makeSession(keyProvider, self)
        session = roomSession
        scheduleJoinDeadline()
        let url: String = parameters.url
        let token: String = parameters.token
        connectTask = Task { @MainActor [weak self] in
            do {
                try await roomSession.connect(url: url, token: token)
            } catch {
                self?.terminate(.connectionFailed)
                return
            }
            self?.handleConnected()
        }
    }


    /// Ends the call. The state reports the end when the room has left, or when the leave deadline has passed.
    public func stop() {
        terminate(.hungUp)
    }


    func roomDidFailToConnect() {
        terminate(.connectionFailed)
    }


    func roomDidDisconnectUnexpectedly() {
        terminate(.disconnected)
    }


    func roomDidReportMediaEncryption(_ encryptionState: LiveKitMediaEncryptionState) {
        if encryptionState == .failed {
            terminate(.mediaEncryptionFailed)
        }
    }


    /// Builds the shared-key provider of the call. The key must be the 256-byte DH key; the derivation matches the Android call.
    static func makeKeyProvider(authKey: Data) throws -> BaseKeyProvider {
        guard authKey.count == 256 else {
            throw LiveKitCallContextError.invalidAuthKey
        }
        let options: KeyProviderOptions = KeyProviderOptions(
            sharedKey: true,
            ratchetSalt: Data("LKFrameEncryptionKey".utf8),
            ratchetWindowSize: 0,
            uncryptedMagicBytes: Data("LK-ROCKS".utf8),
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true,
            keyDerivationAlgorithm: .hkdf
        )
        let provider: BaseKeyProvider = BaseKeyProvider(options: options)
        provider.setKey(keyData: authKey, index: 0)
        return provider
    }


    nonisolated static func makeSDKSession(
        _ keyProvider: BaseKeyProvider,
        _ sink: LiveKitRoomEventSink
    ) -> LiveKitRoomSession {
        return LiveKitSDKRoomSession(keyProvider: keyProvider, sink: sink)
    }


    private var isEnded: Bool {
        if case .ended = state {
            return true
        }
        return false
    }


    private func handleConnected() {
        guard !isTerminating, state == .connecting else {
            return
        }
        joinTimerTask?.cancel()
        joinTimerTask = nil
        setState(.connected)
    }


    private func scheduleJoinDeadline() {
        let nanoseconds: UInt64 = LiveKitCallContext.nanoseconds(from: joinDeadline)
        joinTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self?.terminate(.joinTimedOut)
        }
    }


    private func terminate(_ reason: LiveKitCallEndReason) {
        guard !isTerminating else {
            return
        }
        isTerminating = true
        joinTimerTask?.cancel()
        connectTask?.cancel()
        guard let roomSession: LiveKitRoomSession = session else {
            finish(reason)
            return
        }
        session = nil
        let nanoseconds: UInt64 = LiveKitCallContext.nanoseconds(from: leaveDeadline)
        leaveTask = Task { @MainActor [weak self] in
            await roomSession.disconnect()
            self?.leaveTimerTask?.cancel()
            self?.finish(reason)
        }
        leaveTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self?.finish(reason)
        }
    }


    private func finish(_ reason: LiveKitCallEndReason) {
        guard !isEnded else {
            return
        }
        setState(.ended(reason))
    }


    private func setState(_ newState: LiveKitCallState) {
        state = newState
        onStateChanged?(newState)
    }


    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        return UInt64(max(0, seconds) * 1_000_000_000)
    }
}


/// Adapts the LiveKit room delegate to the call context. LiveKit calls it on its own threads, so every event hops to the main actor.
private final class LiveKitRoomDelegateBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private weak var sink: LiveKitRoomEventSink?


    init(sink: LiveKitRoomEventSink) {
        self.sink = sink
        super.init()
    }


    func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            self?.sink?.roomDidFailToConnect()
        }
    }


    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in
            self?.sink?.roomDidDisconnectUnexpectedly()
        }
    }


    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        let encryptionState: LiveKitMediaEncryptionState = LiveKitMediaEncryptionState(e2eeState: state)
        Task { @MainActor [weak self] in
            self?.sink?.roomDidReportMediaEncryption(encryptionState)
        }
    }
}


/// The production room session: a LiveKit `Room` with the shared-key encryption of the call.
private final class LiveKitSDKRoomSession: LiveKitRoomSession {
    private let bridge: LiveKitRoomDelegateBridge
    private let room: Room


    init(keyProvider: BaseKeyProvider, sink: LiveKitRoomEventSink) {
        let roomBridge: LiveKitRoomDelegateBridge = LiveKitRoomDelegateBridge(sink: sink)
        let encryption: EncryptionOptions = EncryptionOptions(keyProvider: keyProvider)
        let roomOptions: RoomOptions = RoomOptions(encryptionOptions: encryption)
        self.bridge = roomBridge
        self.room = Room(
            delegate: roomBridge,
            connectOptions: nil,
            roomOptions: roomOptions
        )
    }


    func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
    }


    func disconnect() async {
        await room.disconnect()
    }
}
