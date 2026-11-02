#if os(iOS)

import AVFoundation
import Foundation
import LiveKit
import SwiftSignalKit
import UIKit


/// The local camera of a private call. The front or the back camera is captured by the LiveKit camera capturer.
public final class LiveKitCallVideoCapturer: LiveKitPrivateVideoCapturer {
    public var videoKind: LiveKitPrivateVideoKind {
        return .camera
    }


    private var isFrontCamera: Bool
    private var track: LocalVideoTrack?
    private var trackTask: Task<LocalVideoTrack?, Never>?
    private var switchTicket: UInt64 = 0
    private var isEnabled: Bool = true
    private var isStopped: Bool = false


    /// A camera capturer for the front or the back camera. The camera track is created on first use.
    public init(isFrontCamera: Bool) {
        self.isFrontCamera = isFrontCamera
        self.track = nil
        self.trackTask = nil
    }


    /// The camera track as a publishable value, created on first use. Nil when the track cannot be created.
    @MainActor
    public func makeLocalVideoTrack() async -> LiveKitLocalVideoTrack? {
        guard !self.isStopped else {
            return nil
        }
        guard let track: LocalVideoTrack = await self.ensureTrack() else {
            return nil
        }
        guard !self.isStopped else {
            return nil
        }
        return LiveKitCallLocalCameraTrack(sdkTrack: track)
    }


    /// Emits the local camera frames. The track is created on the first use.
    public func video() -> Signal<OngoingGroupCallContext.VideoFrameData, NoError> {
        return LiveKitVideoFrames.frames(of: self.trackSignal())
    }


    /// Switches between the front and the back camera. A switch made while the track is being created applies once it exists.
    public func switchCamera() {
        Task { @MainActor in
            self.isFrontCamera = !self.isFrontCamera
            self.switchTicket += 1
            let ticket: UInt64 = self.switchTicket
            guard self.track != nil || self.trackTask != nil else {
                return
            }
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                return
            }
            guard self.switchTicket == ticket else {
                return
            }
            guard let cameraCapturer: CameraCapturer = track.capturer as? CameraCapturer else {
                return
            }
            let position: AVCaptureDevice.Position = self.isFrontCamera ? .front : .back
            _ = try? await cameraCapturer.set(cameraPosition: position)
        }
    }


    /// Starts the local camera, or pauses it. A pause mutes the track and stops the capture.
    ///
    /// The camera track is created first if it does not exist yet, so the change takes effect after that.
    public func setIsVideoEnabled(_ isEnabled: Bool) {
        Task { @MainActor in
            self.isEnabled = isEnabled
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                return
            }
            if self.isEnabled && !self.isStopped {
                _ = try? await track.start()
                _ = try? await track.unmute()
            } else {
                _ = try? await track.mute()
                _ = try? await track.stop()
            }
        }
    }


    /// Stops the camera capture for good. A preview or an enable made after this does not start the camera again.
    public func stop() {
        Task { @MainActor in
            self.isStopped = true
            guard self.track != nil || self.trackTask != nil else {
                return
            }
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                return
            }
            _ = try? await track.mute()
            _ = try? await track.stop()
        }
    }


    /// Mutes and stops the published track again while the capture is paused or stopped, because publishing starts the track.
    @MainActor
    public func syncEnabledState() async {
        guard !self.isEnabled || self.isStopped, let track: LocalVideoTrack = self.track else {
            return
        }
        _ = try? await track.mute()
        _ = try? await track.stop()
    }


    /// Renders the local track into a LiveKit view and returns it with the closures of the presentation view.
    ///
    /// The completion runs on the main actor, after the track is ready. It receives nil if no track can be created.
    public func makeOutgoingVideoView(completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        Task { @MainActor in
            guard let track: LocalVideoTrack = await self.previewTrack() else {
                completion(nil)
                return
            }
            completion(makeLiveKitCallOutgoingVideoPresentationView(track: track))
        }
    }


    /// Emits the local track once it is created. Emits nil when no track can be created.
    private func trackSignal() -> Signal<VideoTrack?, NoError> {
        return Signal { (subscriber: Subscriber<VideoTrack?, NoError>) -> Disposable in
            let task: Task<Void, Never> = Task { @MainActor in
                let track: LocalVideoTrack? = await self.previewTrack()
                subscriber.putNext(track)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }


    /// Returns the local track started for a preview. The track is started only while the capturer is enabled and not stopped.
    @MainActor
    private func previewTrack() async -> LocalVideoTrack? {
        guard let track: LocalVideoTrack = await self.ensureTrack() else {
            return nil
        }
        if self.isEnabled && !self.isStopped {
            _ = try? await track.start()
        }
        return track
    }


    /// Returns the local track, waiting for its creation if it is still pending. The camera track is created on the first call.
    @MainActor
    private func ensureTrack() async -> LocalVideoTrack? {
        if let existing: LocalVideoTrack = self.track {
            return existing
        }
        if self.trackTask == nil {
            let isFrontCamera: Bool = self.isFrontCamera
            self.trackTask = Task { @MainActor [weak self] () -> LocalVideoTrack? in
                let captureCode: LiveKitCaptureCode = isFrontCamera ? .front : .back
                let created: LocalVideoTrack? = await LiveKitVideoSources.createCameraTrack(captureCode: captureCode, deviceId: "")
                self?.track = created
                return created
            }
        }
        guard let pending: Task<LocalVideoTrack?, Never> = self.trackTask else {
            return nil
        }
        return await pending.value
    }
}


/// The LiveKit camera track of this device, as the call engine publishes it.
private final class LiveKitCallLocalCameraTrack: LiveKitLocalVideoTrack {
    let sdkTrack: LocalVideoTrack?


    init(sdkTrack: LocalVideoTrack?) {
        self.sdkTrack = sdkTrack
    }
}


/// Builds the presentation view of a local camera track: a LiveKit view that reports its first frame and the aspect ratio of the track.
private func makeLiveKitCallOutgoingVideoPresentationView(track: VideoTrack) -> OngoingCallContextPresentationCallVideoView {
    let videoView: VideoView = VideoView(frame: .zero)
    videoView.track = track
    videoView.layoutMode = .fit
    let bridge: LiveKitCallOutgoingVideoBridge = LiveKitCallOutgoingVideoBridge(track: track)
    videoView.add(delegate: bridge)
    return OngoingCallContextPresentationCallVideoView(
        view: videoView,
        setOnFirstFrameReceived: { (callback: ((Float) -> Void)?) -> Void in
            bridge.onFirstFrame = callback
        },
        getOrientation: {
            return .rotation0
        },
        getAspect: {
            return bridge.aspect
        },
        setOnOrientationUpdated: { (_: ((OngoingCallVideoOrientation, CGFloat) -> Void)?) -> Void in
        },
        setOnIsMirroredUpdated: { (_: ((Bool) -> Void)?) -> Void in
        },
        updateIsEnabled: { (isEnabled: Bool) -> Void in
            videoView.isEnabled = isEnabled
        }
    )
}


/// Reports the first rendered frame of a call view and the aspect ratio of its track.
private final class LiveKitCallOutgoingVideoBridge: NSObject, VideoViewDelegate, @unchecked Sendable {
    var onFirstFrame: ((Float) -> Void)?
    private let track: VideoTrack
    private var hasReportedFirstFrame: Bool = false


    init(track: VideoTrack) {
        self.track = track
        super.init()
    }


    var aspect: CGFloat {
        guard let dimensions: Dimensions = self.track.dimensions else {
            return 0
        }
        guard dimensions.height > 0 else {
            return 0
        }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }


    @objc(videoView:didUpdateIsRendering:)
    func videoView(_ videoView: VideoView, didUpdate isRendering: Bool) {
        guard isRendering, !hasReportedFirstFrame else {
            return
        }
        hasReportedFirstFrame = true
        let reportedAspect: Float = Float(aspect)
        DispatchQueue.main.async { [weak self] in
            self?.onFirstFrame?(reportedAspect)
        }
    }
}

#endif
