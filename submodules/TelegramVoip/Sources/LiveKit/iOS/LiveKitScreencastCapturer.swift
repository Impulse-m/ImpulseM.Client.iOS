#if os(iOS)
import Foundation
import CoreMedia
import ImageIO
import LiveKit


/// The screen share source of a LiveKit call on iOS. Broadcast frames are injected into a buffer track.
public final class LiveKitScreencastCapturer: LiveKitPrivateVideoCapturer {
    public var videoKind: LiveKitPrivateVideoKind {
        return .screen
    }


    private static let maxFrameWaitSteps: Int = 60
    private static let frameWaitStepNanoseconds: UInt64 = 50_000_000
    private let stateLock: NSLock = NSLock()
    private var bufferCapturer: BufferCapturer?


    public init() {
    }


    /// Creates the buffer track of the screen share. The track is returned once its dimensions are resolved from the first injected frame.
    ///
    /// Returns nil when no frame arrives within three seconds, so the publish is skipped.
    @MainActor
    public func makeLocalVideoTrack() async -> LiveKitLocalVideoTrack? {
        let createBuffer: (String, Track.Source, BufferCaptureOptions, Bool) async -> LocalVideoTrack = LocalVideoTrack.createBufferTrack
        let track: LocalVideoTrack = await createBuffer(Track.screenShareVideoName, .screenShareVideo, BufferCaptureOptions(), false)
        guard let capturer: BufferCapturer = track.capturer as? BufferCapturer else {
            return nil
        }
        self.setBufferCapturer(capturer)
        guard await self.waitForDimensions(of: capturer) else {
            self.clearBufferCapturer(capturer)
            return nil
        }
        return LiveKitScreencastLocalVideoTrack(sdkTrack: track)
    }


    /// Injects a broadcast frame into the screen share track. Frames arriving before the track exists are dropped.
    public func injectSampleBuffer(_ sampleBuffer: CMSampleBuffer, rotation: CGImagePropertyOrientation, completion: @escaping () -> Void) {
        defer {
            completion()
        }
        guard let capturer: BufferCapturer = self.currentBufferCapturer() else {
            return
        }
        guard let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        capturer.capture(pixelBuffer, rotation: LiveKitScreencastCapturer.videoRotation(for: rotation))
    }


    @MainActor
    private func waitForDimensions(of capturer: BufferCapturer) async -> Bool {
        var steps: Int = 0
        while capturer.dimensions == nil {
            guard steps < LiveKitScreencastCapturer.maxFrameWaitSteps else {
                return false
            }
            steps += 1
            do {
                try await Task.sleep(nanoseconds: LiveKitScreencastCapturer.frameWaitStepNanoseconds)
            } catch {
                return false
            }
        }
        return true
    }


    private func setBufferCapturer(_ capturer: BufferCapturer) {
        self.stateLock.lock()
        defer {
            self.stateLock.unlock()
        }
        self.bufferCapturer = capturer
    }


    private func clearBufferCapturer(_ capturer: BufferCapturer) {
        self.stateLock.lock()
        defer {
            self.stateLock.unlock()
        }
        if self.bufferCapturer === capturer {
            self.bufferCapturer = nil
        }
    }


    private func currentBufferCapturer() -> BufferCapturer? {
        self.stateLock.lock()
        defer {
            self.stateLock.unlock()
        }
        return self.bufferCapturer
    }


    private static func videoRotation(for orientation: CGImagePropertyOrientation) -> VideoRotation {
        switch orientation {
        case .left:
            return ._90
        case .down:
            return ._180
        case .right:
            return ._270
        default:
            return ._0
        }
    }
}


/// Wraps the buffer track of the screen share as a publishable value.
private final class LiveKitScreencastLocalVideoTrack: LiveKitLocalVideoTrack {
    let sdkTrack: LocalVideoTrack?

    init(sdkTrack: LocalVideoTrack?) {
        self.sdkTrack = sdkTrack
    }
}
#endif
