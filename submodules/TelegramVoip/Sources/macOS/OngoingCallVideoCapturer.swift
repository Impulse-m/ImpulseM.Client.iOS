//
//  OngoingCallVideoCapturer.swift
//  TelegramVoip
//
//  Created by Mikhail Filimonov on 07.01.2021.
//

import Foundation
import Cocoa
import AVFoundation
import LiveKit
import SwiftSignalKit


public enum OngoingCallVideoOrientation {
    case rotation0
    case rotation90
    case rotation180
    case rotation270
}



public final class OngoingCallContextPresentationCallVideoView {
    public let view: NSView
    public let setOnFirstFrameReceived: (((Float) -> Void)?) -> Void
    public let getOrientation: () -> OngoingCallVideoOrientation
    public let getAspect: () -> CGFloat
    public let setOnOrientationUpdated: (((OngoingCallVideoOrientation, CGFloat) -> Void)?) -> Void
    public let setVideoContentMode: (CALayerContentsGravity) -> Void
    public let setOnIsMirroredUpdated: (((Bool) -> Void)?) -> Void
    public let setIsPaused: (Bool) -> Void
    public let renderToSize:(NSSize, Bool)->Void
    public init(
        view: NSView,
        setOnFirstFrameReceived: @escaping (((Float) -> Void)?) -> Void,
        getOrientation: @escaping () -> OngoingCallVideoOrientation,
        getAspect: @escaping () -> CGFloat,
        setOnOrientationUpdated: @escaping (((OngoingCallVideoOrientation, CGFloat) -> Void)?) -> Void,
        setVideoContentMode: @escaping(CALayerContentsGravity) -> Void,
        setOnIsMirroredUpdated: @escaping (((Bool) -> Void)?) -> Void,
        setIsPaused: @escaping(Bool) -> Void,
        renderToSize: @escaping(NSSize, Bool) -> Void
        ) {
        self.view = view
        self.setOnFirstFrameReceived = setOnFirstFrameReceived
        self.getOrientation = getOrientation
        self.getAspect = getAspect
        self.setOnOrientationUpdated = setOnOrientationUpdated
        self.setVideoContentMode = setVideoContentMode
        self.setOnIsMirroredUpdated = setOnIsMirroredUpdated
        self.setIsPaused = setIsPaused
        self.renderToSize = renderToSize
    }
}



/// The local video of a call: the camera selected by `deviceId`, or a macOS screen share. The track is built by `LiveKitVideoSources`.
public final class OngoingCallVideoCapturer {
    public private(set) var deviceId: String
    public let captureCode: LiveKitCaptureCode
    public private(set) var track: LocalVideoTrack?
    private var onFatalError: (() -> Void)?
    private var onPause: ((Bool) -> Void)?
    private var trackTask: Task<LocalVideoTrack?, Never>?
    private let switchSequence: VideoInputSwitchSequence = VideoInputSwitchSequence()


    /// A camera capturer. An empty identifier selects the default camera. The camera track is created on first use.
    public init(_ deviceId: String = "") {
        self.deviceId = deviceId
        self.captureCode = .front
        self.track = nil
        self.trackTask = nil
    }


    /// A screen share capturer for a source chosen with `MacOSScreenCapturer.sources(for:)`. Screen share needs macOS 12.3.
    ///
    /// The track is created in the background and `track` stays nil until it is ready.
    @available(macOS 12.3, *)
    public init(screenSource: MacOSScreenCaptureSource) {
        self.deviceId = ""
        self.captureCode = .screen
        self.track = nil
        let captureSource: MacOSScreenCaptureSource = screenSource
        self.trackTask = Task { @MainActor [weak self] () -> LocalVideoTrack? in
            let created: LocalVideoTrack = await LiveKitVideoSources.createMacOSScreenShareTrack(source: captureSource)
            self?.track = created
            return created
        }
    }


    /// Starts the local video, or pauses it. A pause mutes the track and stops the capture.
    ///
    /// The camera track is created first if it does not exist yet, so the change takes effect after that.
    public func setIsVideoEnabled(_ value: Bool) {
        Task { @MainActor in
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                return
            }
            let pauseHandler: ((Bool) -> Void)? = self.onPause
            let fatalErrorHandler: (() -> Void)? = self.onFatalError
            pauseHandler?(!value)
            do {
                if value {
                    try await track.start()
                    try await track.unmute()
                } else {
                    try await track.mute()
                    try await track.stop()
                }
            } catch {
                if value {
                    fatalErrorHandler?()
                }
            }
        }
    }


    /// Renders the local track into a LiveKit view and returns it with the closures of the presentation view.
    ///
    /// The completion runs on the main actor, after the track is ready. It receives nil if no track exists.
    public func makeOutgoingVideoView(completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        Task { @MainActor in
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                completion(nil)
                return
            }
            completion(makeLiveKitCallVideoPresentationView(track: track))
        }
    }


    /// The camera track as a publishable value, created on first use. Nil when the track cannot be created.
    @MainActor
    public func makeLocalVideoTrack() async -> LiveKitLocalVideoTrack? {
        guard let track: LocalVideoTrack = await self.ensureTrack() else {
            return nil
        }
        return LiveKitSDKLocalVideoTrack(sdkTrack: track)
    }


    /// Emits the local track once it is created. Emits nil when no track can be created.
    public func video() -> Signal<VideoTrack?, NoError> {
        return Signal { (subscriber: Subscriber<VideoTrack?, NoError>) -> Disposable in
            let task: Task<Void, Never> = Task { @MainActor in
                let track: LocalVideoTrack? = await self.ensureTrack()
                subscriber.putNext(track)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }


    public func setOnFatalError(_ onError: @escaping () -> Void) {
        self.onFatalError = {
            DispatchQueue.main.async(execute: onError)
        }
    }


    public func setOnPause(_ onPause: @escaping (Bool) -> Void) {
        self.onPause = { pause in
            DispatchQueue.main.async(execute: {
                onPause(pause)
            })
        }
    }


    /// Switches the camera. The device identifier selects the camera; an empty identifier selects the default one.
    ///
    /// If the camera track is still being created, the switch waits for it and then applies the device of the latest call. A switch superseded by a newer one does nothing.
    public func switchVideoInput(_ deviceId: String) {
        self.deviceId = deviceId
        guard self.captureCode != .screen else {
            return
        }
        let ticket: UInt64 = self.switchSequence.advance()
        guard self.track != nil || self.trackTask != nil else {
            return
        }
        Task { @MainActor in
            guard let track: LocalVideoTrack = await self.ensureTrack() else {
                return
            }
            guard self.switchSequence.isCurrent(ticket) else {
                return
            }
            guard let cameraCapturer: CameraCapturer = track.capturer as? CameraCapturer else {
                return
            }
            let device: AVCaptureDevice? = self.deviceId.isEmpty ? nil : AVCaptureDevice(uniqueID: self.deviceId)
            let options: CameraCaptureOptions = CameraCaptureOptions(device: device, position: .front)
            _ = try? await cameraCapturer.set(options: options)
        }
    }


    /// Returns the local track, waiting for its creation if it is still pending. The camera track is created on the first call.
    @MainActor
    private func ensureTrack() async -> LocalVideoTrack? {
        if let existing: LocalVideoTrack = self.track {
            return existing
        }
        if self.trackTask == nil {
            let captureCode: LiveKitCaptureCode = self.captureCode
            let deviceId: String = self.deviceId
            self.trackTask = Task { @MainActor [weak self] () -> LocalVideoTrack? in
                let created: LocalVideoTrack? = await LiveKitVideoSources.createCameraTrack(captureCode: captureCode, deviceId: deviceId)
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



/// Hands out an ascending ticket to each camera switch. Only the newest ticket is current, so a superseded switch does nothing.
final class VideoInputSwitchSequence {
    private let lock: NSLock = NSLock()
    private var latest: UInt64 = 0


    /// Starts a new switch and returns its ticket.
    func advance() -> UInt64 {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        self.latest += 1
        return self.latest
    }


    /// True while no newer switch has started after the given ticket.
    func isCurrent(_ ticket: UInt64) -> Bool {
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        return self.latest == ticket
    }
}



/// The LiveKit camera or screen track of this device, as the call engine publishes it.
public final class LiveKitSDKLocalVideoTrack: LiveKitLocalVideoTrack {
    public let sdkTrack: LocalVideoTrack?


    init(sdkTrack: LocalVideoTrack?) {
        self.sdkTrack = sdkTrack
    }
}


/// Renders a LiveKit video track into a call video view. The local preview and the remote video of a call use this view.
public func makeLiveKitCallVideoPresentationView(track: VideoTrack) -> OngoingCallContextPresentationCallVideoView {
    let videoView: VideoView = VideoView(frame: .zero)
    videoView.track = track
    videoView.layoutMode = .fit
    let bridge: LiveKitCallVideoBridge = LiveKitCallVideoBridge(track: track)
    videoView.add(delegate: bridge)
    return OngoingCallContextPresentationCallVideoView(
        view: videoView,
        setOnFirstFrameReceived: { callback in
            bridge.onFirstFrame = callback
        },
        getOrientation: {
            return .rotation0
        },
        getAspect: {
            return bridge.aspect
        },
        setOnOrientationUpdated: { _ in
        },
        setVideoContentMode: { gravity in
            let isFill: Bool = gravity == .resizeAspectFill
            videoView.layoutMode = isFill ? .fill : .fit
        },
        setOnIsMirroredUpdated: { _ in
        },
        setIsPaused: { paused in
            videoView.isEnabled = !paused
        },
        renderToSize: { _, _ in
        }
    )
}


/// Reports the first rendered frame of a LiveKit call view and the aspect ratio of its track.
private final class LiveKitCallVideoBridge: NSObject, VideoViewDelegate {
    var onFirstFrame: ((Float) -> Void)?
    private let track: VideoTrack
    private var hasReportedFirstFrame: Bool = false


    init(track: VideoTrack) {
        self.track = track
        super.init()
    }


    var aspect: CGFloat {
        guard let dimensions: LiveKit.Dimensions = self.track.dimensions else {
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
