#if os(iOS)

import AVFoundation
import Foundation
import LiveKit
import SwiftSignalKit
import TgVoipWebrtc


/// Turns the LiveKit video tracks of a call into the frame values that the call UI renders.
public enum LiveKitVideoFrames {
    /// Emits the frames of every track that `track` emits. The renderer is attached to a track when it is emitted,
    /// detached when the next track is emitted, and detached when the signal is disposed.
    public static func frames(of track: Signal<VideoTrack?, NoError>) -> Signal<OngoingGroupCallContext.VideoFrameData, NoError> {
        return Signal { (subscriber: Subscriber<OngoingGroupCallContext.VideoFrameData, NoError>) -> Disposable in
            let sink: LiveKitVideoFrameSink = LiveKitVideoFrameSink(subscriber: subscriber)
            let route: LiveKitVideoFrameRoute = LiveKitVideoFrameRoute(sink: sink)
            let upstream: Disposable = track.start(next: { (nextTrack: VideoTrack?) in
                route.attach(nextTrack)
            })
            return ActionDisposable {
                upstream.dispose()
                route.close()
            }
        }
    }
}


/// Holds the track that the sink is attached to. Attaching and detaching happen under a lock, so each track is detached exactly once.
private final class LiveKitVideoFrameRoute: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private let sink: LiveKitVideoFrameSink
    private var track: VideoTrack?
    private var isClosed: Bool = false


    init(sink: LiveKitVideoFrameSink) {
        self.sink = sink
    }


    func attach(_ nextTrack: VideoTrack?) {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !isClosed else {
            return
        }
        if track === nextTrack {
            return
        }
        track?.remove(videoRenderer: sink)
        nextTrack?.add(videoRenderer: sink)
        track = nextTrack
    }


    func close() {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !isClosed else {
            return
        }
        isClosed = true
        track?.remove(videoRenderer: sink)
        track = nil
        sink.close()
    }
}


/// Receives the frames of an attached track and passes them on as call video frame data.
private final class LiveKitVideoFrameSink: NSObject, VideoRenderer, @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var subscriber: Subscriber<OngoingGroupCallContext.VideoFrameData, NoError>?


    init(subscriber: Subscriber<OngoingGroupCallContext.VideoFrameData, NoError>) {
        self.subscriber = subscriber
        super.init()
    }


    @MainActor
    var isAdaptiveStreamEnabled: Bool {
        return true
    }


    @MainActor
    var adaptiveStreamSize: CGSize {
        return .zero
    }


    func render(frame: VideoFrame) {
        let current: Subscriber<OngoingGroupCallContext.VideoFrameData, NoError>? = currentSubscriber()
        guard let subscriber: Subscriber<OngoingGroupCallContext.VideoFrameData, NoError> = current else {
            return
        }
        guard let frameData: OngoingGroupCallContext.VideoFrameData = LiveKitVideoFrameConverter.frameData(from: frame) else {
            return
        }
        subscriber.putNext(frameData)
    }


    func close() {
        lock.lock()
        defer {
            lock.unlock()
        }
        subscriber = nil
    }


    private func currentSubscriber() -> Subscriber<OngoingGroupCallContext.VideoFrameData, NoError>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return subscriber
    }
}


/// Converts LiveKit frames into the frame data of the call UI. Pixel buffers become native buffers and I420 frames become I420 buffers.
private enum LiveKitVideoFrameConverter {
    static func frameData(from frame: VideoFrame) -> OngoingGroupCallContext.VideoFrameData? {
        let buffer: CallVideoFrameBuffer
        if let pixelVideoBuffer: CVPixelVideoBuffer = frame.buffer as? CVPixelVideoBuffer {
            buffer = LiveKitCallNativeFrameBuffer(pixelBuffer: pixelVideoBuffer.pixelBuffer)
        } else if let i420VideoBuffer: I420VideoBuffer = frame.buffer as? I420VideoBuffer {
            buffer = i420VideoBuffer.withUnsafePlanes { (planes: I420VideoBuffer) -> CallVideoFrameBuffer in
                return makeI420Buffer(planes: planes)
            }
        } else {
            return nil
        }
        let rawFrame: CallVideoFrameData = LiveKitCallVideoFrameData(
            buffer: buffer,
            width: frame.dimensions.width,
            height: frame.dimensions.height,
            orientation: webrtcOrientation(rotation: frame.rotation)
        )
        return OngoingGroupCallContext.VideoFrameData(frameData: rawFrame)
    }


    /// Copies the planes of an I420 buffer, so that the frame data stays valid after the SDK releases the buffer.
    private static func makeI420Buffer(planes: I420VideoBuffer) -> CallVideoFrameBuffer {
        let yCount: Int = Int(planes.strideY) * Int(planes.height)
        let uCount: Int = Int(planes.strideU) * Int(planes.chromaHeight)
        let vCount: Int = Int(planes.strideV) * Int(planes.chromaHeight)
        let yData: Data = Data(bytes: planes.dataY, count: yCount)
        let uData: Data = Data(bytes: planes.dataU, count: uCount)
        let vData: Data = Data(bytes: planes.dataV, count: vCount)
        return LiveKitCallI420FrameBuffer(
            width: planes.width,
            height: planes.height,
            y: yData,
            strideY: planes.strideY,
            u: uData,
            strideU: planes.strideU,
            v: vData,
            strideV: planes.strideV
        )
    }


    private static func webrtcOrientation(rotation: VideoRotation) -> OngoingCallVideoOrientationWebrtc {
        switch rotation.rawValue {
        case 90:
            return .orientation90

        case 180:
            return .orientation180

        case 270:
            return .orientation270

        default:
            return .orientation0
        }
    }
}


/// A pixel buffer of a LiveKit frame. The properties are overridden, because the Objective-C class has no Swift initializer.
private final class LiveKitCallNativeFrameBuffer: CallVideoFrameNativePixelBuffer {
    private let storedPixelBuffer: CVPixelBuffer


    init(pixelBuffer: CVPixelBuffer) {
        self.storedPixelBuffer = pixelBuffer
        super.init()
    }


    override var pixelBuffer: CVPixelBuffer {
        return storedPixelBuffer
    }
}


/// The planes of an I420 LiveKit frame, copied into the frame data.
private final class LiveKitCallI420FrameBuffer: CallVideoFrameI420Buffer {
    private let storedWidth: Int32
    private let storedHeight: Int32
    private let storedY: Data
    private let storedStrideY: Int32
    private let storedU: Data
    private let storedStrideU: Int32
    private let storedV: Data
    private let storedStrideV: Int32


    init(
        width: Int32,
        height: Int32,
        y: Data,
        strideY: Int32,
        u: Data,
        strideU: Int32,
        v: Data,
        strideV: Int32
    ) {
        self.storedWidth = width
        self.storedHeight = height
        self.storedY = y
        self.storedStrideY = strideY
        self.storedU = u
        self.storedStrideU = strideU
        self.storedV = v
        self.storedStrideV = strideV
        super.init()
    }


    override var width: Int32 {
        return storedWidth
    }


    override var height: Int32 {
        return storedHeight
    }


    override var y: Data {
        return storedY
    }


    override var strideY: Int32 {
        return storedStrideY
    }


    override var u: Data {
        return storedU
    }


    override var strideU: Int32 {
        return storedStrideU
    }


    override var v: Data {
        return storedV
    }


    override var strideV: Int32 {
        return storedStrideV
    }
}


/// The frame data of a LiveKit frame. Frames carry no mirroring and no device-relative orientation.
private final class LiveKitCallVideoFrameData: CallVideoFrameData {
    private let storedBuffer: CallVideoFrameBuffer
    private let storedWidth: Int32
    private let storedHeight: Int32
    private let storedOrientation: OngoingCallVideoOrientationWebrtc


    init(
        buffer: CallVideoFrameBuffer,
        width: Int32,
        height: Int32,
        orientation: OngoingCallVideoOrientationWebrtc
    ) {
        self.storedBuffer = buffer
        self.storedWidth = width
        self.storedHeight = height
        self.storedOrientation = orientation
        super.init()
    }


    override var buffer: CallVideoFrameBuffer {
        return storedBuffer
    }


    override var width: Int32 {
        return storedWidth
    }


    override var height: Int32 {
        return storedHeight
    }


    override var orientation: OngoingCallVideoOrientationWebrtc {
        return storedOrientation
    }


    override var hasDeviceRelativeOrientation: Bool {
        return false
    }


    override var deviceRelativeOrientation: OngoingCallVideoOrientationWebrtc {
        return .orientation0
    }


    override var mirrorHorizontally: Bool {
        return false
    }


    override var mirrorVertically: Bool {
        return false
    }
}

#endif
