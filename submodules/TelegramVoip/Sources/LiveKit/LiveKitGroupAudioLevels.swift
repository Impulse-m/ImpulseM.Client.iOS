import AVFoundation
import Foundation
import LiveKit


/// A clock on a monotonic timeline, in milliseconds. Tests use a fake clock.
public protocol LiveKitAudioLevelClock: AnyObject {
    /// The current time in milliseconds. The value never goes backwards.
    func nowMilliseconds() -> Int64
}


/// The clock of the running process, based on the time since boot.
public final class LiveKitSystemAudioLevelClock: LiveKitAudioLevelClock {
    public init() {
    }


    public func nowMilliseconds() -> Int64 {
        let uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime
        return Int64(uptimeSeconds * 1000.0)
    }
}


/// Measures the loudness of one audio track from the buffers its renderer receives. The level is the RMS of the samples received since the previous `takeLevel()` call.
public final class LiveKitGroupAudioMeter: AudioRenderer, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var sumOfSquares: Double = 0
    private var sampleCount: Int = 0


    public init() {
    }


    /// Adds the samples of one buffer. The SDK calls this on the audio thread.
    public func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData: UnsafePointer<UnsafeMutablePointer<Float>> = pcmBuffer.floatChannelData else {
            return
        }
        let channelCount: Int = Int(pcmBuffer.format.channelCount)
        let frameCount: Int = Int(pcmBuffer.frameLength)
        var squares: Double = 0
        for channelIndex in 0 ..< channelCount {
            let samples: UnsafeMutablePointer<Float> = channelData[channelIndex]
            for frameIndex in 0 ..< frameCount {
                let value: Double = Double(samples[frameIndex])
                squares += value * value
            }
        }
        addSamples(squares: squares, count: channelCount * frameCount)
    }


    /// Returns the RMS of the samples received since the previous call and starts a new window. Returns 0 when no samples arrived.
    public func takeLevel() -> Float {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard sampleCount > 0 else {
            return 0
        }
        let level: Double = (sumOfSquares / Double(sampleCount)).squareRoot()
        sumOfSquares = 0
        sampleCount = 0
        return Float(level)
    }


    private func addSamples(
        squares: Double,
        count: Int
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }
        sumOfSquares += squares
        sampleCount += count
    }
}


/// Keeps one meter per audio track of a group call and samples them every 100 ms. The caller drives the sampling from its own timer and calls `sampleIfDue()`. Use from one thread only.
public final class LiveKitGroupAudioLevels {
    /// The interval between two samples, in milliseconds.
    public static let sampleIntervalMilliseconds: Int64 = 100

    private let clock: LiveKitAudioLevelClock
    private var meters: [LiveKitGroupAudioLevelKey: LiveKitGroupAudioMeter] = [:]
    private var isLocalMuted: Bool = false
    private var lastSampleMilliseconds: Int64?


    public init(clock: LiveKitAudioLevelClock) {
        self.clock = clock
    }


    /// Creates the meter of one track and returns it. Attach the returned meter as the audio renderer of that track. A key that already has a meter gets a new one.
    public func addMeter(key: LiveKitGroupAudioLevelKey) -> LiveKitGroupAudioMeter {
        let meter: LiveKitGroupAudioMeter = LiveKitGroupAudioMeter()
        meters[key] = meter
        return meter
    }


    /// Removes the meter of one track. The track is no longer reported.
    public func removeMeter(key: LiveKitGroupAudioLevelKey) {
        meters.removeValue(forKey: key)
    }


    /// Sets whether the local microphone is muted. A muted local track reports 0 and not speaking.
    public func setLocalMuted(_ isMuted: Bool) {
        isLocalMuted = isMuted
    }


    /// Returns one entry per meter when the sample interval has passed since the previous sample, and nil otherwise. The first call always samples. The local entry comes first, then the sources in ascending order. A track is speaking when its level is above 0.
    public func sampleIfDue() -> [(LiveKitGroupAudioLevelKey, Float, Bool)]? {
        let nowMilliseconds: Int64 = clock.nowMilliseconds()
        if let lastSample: Int64 = lastSampleMilliseconds, nowMilliseconds - lastSample < LiveKitGroupAudioLevels.sampleIntervalMilliseconds {
            return nil
        }
        lastSampleMilliseconds = nowMilliseconds
        var entries: [(LiveKitGroupAudioLevelKey, Float, Bool)] = []
        for key in meters.keys.sorted(by: LiveKitGroupAudioLevels.isOrderedBefore(first:second:)) {
            guard let meter: LiveKitGroupAudioMeter = meters[key] else {
                continue
            }
            let measured: Float = meter.takeLevel()
            var level: Float = measured
            if key == .local && isLocalMuted {
                level = 0
            }
            entries.append((key, level, level > 0))
        }
        return entries
    }


    private static func isOrderedBefore(
        first: LiveKitGroupAudioLevelKey,
        second: LiveKitGroupAudioLevelKey
    ) -> Bool {
        switch (first, second) {
        case (.local, .local):
            return false

        case (.local, .source):
            return true

        case (.source, .local):
            return false

        case (.source(let firstSource), .source(let secondSource)):
            return firstSource < secondSource
        }
    }
}
