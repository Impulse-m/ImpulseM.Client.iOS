import XCTest
import AVFoundation
@testable import TelegramVoip


/// A clock that only moves when a test sets `milliseconds`.
final class FakeLiveKitAudioLevelClock: LiveKitAudioLevelClock {
    var milliseconds: Int64 = 0


    func nowMilliseconds() -> Int64 {
        return milliseconds
    }
}


final class LiveKitGroupAudioLevelsTests: XCTestCase {
    func testEachDueSampleReportsOneEntryPerTrackInOrder() throws {
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let levels: LiveKitGroupAudioLevels = LiveKitGroupAudioLevels(clock: clock)
        _ = levels.addMeter(key: .source(9))
        _ = levels.addMeter(key: .local)
        _ = levels.addMeter(key: .source(5))

        let firstSample: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(firstSample.map { $0.0 }, [.local, .source(5), .source(9)])
        XCTAssertEqual(firstSample.map { $0.1 }, [0, 0, 0])
        XCTAssertEqual(firstSample.map { $0.2 }, [false, false, false])

        clock.milliseconds = 50
        XCTAssertNil(levels.sampleIfDue())

        clock.milliseconds = 100
        XCTAssertEqual(try XCTUnwrap(levels.sampleIfDue()).count, 3)
    }


    func testTickWithNoBuffersReportsZeroAndNotSpeaking() throws {
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let levels: LiveKitGroupAudioLevels = LiveKitGroupAudioLevels(clock: clock)
        _ = levels.addMeter(key: .source(5))

        let entries: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].1, 0)
        XCTAssertFalse(entries[0].2)
    }


    func testBufferRmsIsReportedAndWindowRestarts() throws {
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let levels: LiveKitGroupAudioLevels = LiveKitGroupAudioLevels(clock: clock)
        let meter: LiveKitGroupAudioMeter = levels.addMeter(key: .source(5))
        meter.render(pcmBuffer: try makeBuffer(samples: [0.5, -0.5, 0.5, -0.5]))

        let loudSample: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(loudSample[0].0, .source(5))
        XCTAssertEqual(loudSample[0].1, 0.5, accuracy: 0.0001)
        XCTAssertTrue(loudSample[0].2)

        clock.milliseconds = 100
        let silentSample: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(silentSample[0].1, 0)
        XCTAssertFalse(silentSample[0].2)
    }


    func testLocalIsZeroWhileMutedAndReportsAgainAfterUnmute() throws {
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let levels: LiveKitGroupAudioLevels = LiveKitGroupAudioLevels(clock: clock)
        let meter: LiveKitGroupAudioMeter = levels.addMeter(key: .local)
        levels.setLocalMuted(true)
        meter.render(pcmBuffer: try makeBuffer(samples: [1.0, 1.0]))

        let mutedSample: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(mutedSample[0].1, 0)
        XCTAssertFalse(mutedSample[0].2)

        levels.setLocalMuted(false)
        meter.render(pcmBuffer: try makeBuffer(samples: [0.5, 0.5]))
        clock.milliseconds = 100
        let unmutedSample: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(unmutedSample[0].1, 0.5, accuracy: 0.0001)
        XCTAssertTrue(unmutedSample[0].2)
    }


    func testRemovedMeterIsNoLongerReported() throws {
        let clock: FakeLiveKitAudioLevelClock = FakeLiveKitAudioLevelClock()
        let levels: LiveKitGroupAudioLevels = LiveKitGroupAudioLevels(clock: clock)
        _ = levels.addMeter(key: .local)
        _ = levels.addMeter(key: .source(5))
        levels.removeMeter(key: .source(5))

        let entries: [(LiveKitGroupAudioLevelKey, Float, Bool)] = try XCTUnwrap(levels.sampleIfDue())
        XCTAssertEqual(entries.map { $0.0 }, [.local])
    }


    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format: AVAudioFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer: AVAudioPCMBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel: UnsafeMutablePointer<Float> = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0 ..< samples.count {
            channel[index] = samples[index]
        }
        return buffer
    }
}
