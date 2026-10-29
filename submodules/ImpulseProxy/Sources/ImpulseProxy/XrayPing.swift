import Foundation


/// Outcome of one ping. `delay` is in milliseconds; -1 means the config failed or has no result entry.
public struct XrayPingResult: Equatable, Sendable {
    public let delay: Int
    public let error: String?


    public init(
        delay: Int,
        error: String?
    ) {
        self.delay = delay
        self.error = error
    }
}


/// Core operations that a ping round needs from the owner of the managed Xray core.
/// The owner keeps the runtime state: `stopCore` clears it (fail closed) and `restartCore` runs the full start sequence.
public protocol XrayCoreLifecycle: Sendable {
    func stopCore() throws

    func restartCore() throws
}


/// Pings Xray server configs through libXray `pingBatch`. libXray refuses pings while a managed core runs,
/// so a round stops the core, pings, and starts the core again when it was running.
public final class XrayPing: Sendable {
    /// libXray rejects a pingBatch call with more configs than this.
    public static let maxBatchSize: Int = 5

    /// Pause implementation used outside tests: blocks the calling thread.
    public static let blockingPause: @Sendable (Int) -> Void = { (milliseconds: Int) -> Void in
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000.0)
    }

    private static let sequentialMode: String = "sequential"

    private let client: LibXrayClient
    private let pause: @Sendable (Int) -> Void


    public init(
        client: LibXrayClient,
        pause: @escaping @Sendable (Int) -> Void = XrayPing.blockingPause
    ) {
        self.client = client
        self.pause = pause
    }


    /// Runs one ping round with the advanced settings: batches of 5 (or 1 in sequential mode), the pause between chunks,
    /// timeout and url. A running core is stopped before the first ping and restarted after the last chunk.
    /// A core that was not running is not started. An empty round touches nothing.
    public func pingRound(
        configs: [String],
        outboundTag: String,
        advanced: ImpulseProxyState.Advanced,
        coreRunning: Bool,
        lifecycle: XrayCoreLifecycle,
        onChunk: (Int, [XrayPingResult]) -> Bool
    ) throws {
        guard !configs.isEmpty else {
            return
        }
        if coreRunning {
            try lifecycle.stopCore()
        }
        let chunkSize: Int = advanced.pingMode == XrayPing.sequentialMode ? 1 : XrayPing.maxBatchSize
        pingInChunks(
            configs: configs,
            outboundTag: outboundTag,
            url: advanced.pingUrl,
            timeoutSeconds: advanced.pingTimeoutSeconds,
            chunkSize: chunkSize,
            pauseMillis: advanced.pingPauseMillis,
            onChunk: onChunk
        )
        if coreRunning {
            try lifecycle.restartCore()
        }
    }


    /// Pings `configs` in sequential chunks of at most `maxBatchSize` (the chunk size is clamped to 1...5).
    /// A chunk whose call fails reports -1 with the failure text for each of its configs, and the next chunk still runs.
    /// A pause of `pauseMillis` separates chunks, never after the last one. `onChunk` receives the offset of the chunk
    /// and its results; returning false stops the loop before the next chunk.
    public func pingInChunks(
        configs: [String],
        outboundTag: String,
        url: String,
        timeoutSeconds: Int,
        chunkSize: Int,
        pauseMillis: Int,
        onChunk: (Int, [XrayPingResult]) -> Bool
    ) {
        let size: Int = max(1, min(chunkSize, XrayPing.maxBatchSize))
        var offset: Int = 0
        while offset < configs.count {
            let end: Int = min(offset + size, configs.count)
            let chunk: [String] = Array(configs[offset..<end])
            let results: [XrayPingResult] = pingChunk(
                configs: chunk,
                outboundTag: outboundTag,
                url: url,
                timeoutSeconds: timeoutSeconds
            )
            if !onChunk(offset, results) {
                return
            }
            if pauseMillis > 0 && end < configs.count {
                pause(pauseMillis)
            }
            offset = end
        }
    }


    /// Ping-only settings never restart the core. Returns true when a field that affects the core differs.
    public static func restartRequired(
        previous: ImpulseProxyState.Advanced,
        next: ImpulseProxyState.Advanced
    ) -> Bool {
        let left: ImpulseProxyState.Advanced = previous
        var right: ImpulseProxyState.Advanced = next
        right.pingMode = left.pingMode
        right.pingPauseMillis = left.pingPauseMillis
        right.pingTimeoutSeconds = left.pingTimeoutSeconds
        right.pingUrl = left.pingUrl
        right.pingSkipWhileConnected = left.pingSkipWhileConnected
        return left != right
    }


    private func pingChunk(
        configs: [String],
        outboundTag: String,
        url: String,
        timeoutSeconds: Int
    ) -> [XrayPingResult] {
        do {
            return try pingBatch(
                configs: configs,
                outboundTag: outboundTag,
                url: url,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            let text: String = XrayPing.errorText(error)
            return configs.map { (_: String) -> XrayPingResult in
                return XrayPingResult(
                    delay: -1,
                    error: text
                )
            }
        }
    }


    private func pingBatch(
        configs: [String],
        outboundTag: String,
        url: String,
        timeoutSeconds: Int
    ) throws -> [XrayPingResult] {
        let method: String = "pingBatch"
        let items: [[String: Any]] = configs.map { (config: String) -> [String: Any] in
            return [
                "xrayJson": config,
                "outboundTag": outboundTag,
            ]
        }
        let payload: [String: Any] = [
            "configs": items,
            "timeout": timeoutSeconds,
            "url": url,
        ]
        let data: Any? = try client.call(
            method: method,
            payload: payload
        )
        guard let object: [String: Any] = data as? [String: Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        guard let rawResults: [Any] = object["results"] as? [Any] else {
            throw LibXrayError.malformedResponse(method: method)
        }
        var results: [XrayPingResult] = []
        for index: Int in 0..<configs.count {
            guard index < rawResults.count else {
                results.append(XrayPingResult(delay: -1, error: nil))
                continue
            }
            guard let result: [String: Any] = rawResults[index] as? [String: Any] else {
                throw LibXrayError.malformedResponse(method: method)
            }
            guard let success: Bool = XrayPing.boolValue(result["success"]) else {
                throw LibXrayError.malformedResponse(method: method)
            }
            if success {
                guard let delay: Int = XrayPing.numberValue(result["delay"]) else {
                    throw LibXrayError.malformedResponse(method: method)
                }
                results.append(XrayPingResult(delay: delay, error: nil))
            } else {
                let text: String? = result["error"] as? String
                results.append(XrayPingResult(delay: -1, error: text))
            }
        }
        return results
    }


    private static func errorText(
        _ error: Error
    ) -> String {
        if let libXrayError: LibXrayError = error as? LibXrayError, case .methodFailed(_, let message) = libXrayError {
            return message
        }
        return String(describing: error)
    }


    private static func boolValue(
        _ value: Any?
    ) -> Bool? {
        guard let number: NSNumber = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }


    private static func numberValue(
        _ value: Any?
    ) -> Int? {
        guard let number: NSNumber = value as? NSNumber else {
            return nil
        }
        guard CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }
}
