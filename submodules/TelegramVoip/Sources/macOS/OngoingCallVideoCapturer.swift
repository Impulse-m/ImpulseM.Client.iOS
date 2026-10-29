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
    private var outgoingBridge: LiveKitOutgoingVideoBridge?


    /// A camera capturer. An empty identifier selects the default camera. The camera track is created on first use.
    public init(_ deviceId: String = "") {
        self.deviceId = deviceId
        self.captureCode = .front
        self.track = nil
    }


    /// A screen share capturer for a source chosen with `MacOSScreenCapturer.sources(for:)`. Screen share needs macOS 12.3.
    @available(macOS 12.3, *)
    public init(screenSource: MacOSScreenCaptureSource) {
        self.deviceId = ""
        self.captureCode = .screen
        self.track = LiveKitVideoSources.createMacOSScreenShareTrack(source: screenSource)
    }


    /// Starts the local video, or pauses it. A pause mutes the track and stops the capture.
    public func setIsVideoEnabled(_ value: Bool) {
        guard let track: LocalVideoTrack = self.ensureTrack() else {
            return
        }
        let pauseHandler: ((Bool) -> Void)? = self.onPause
        let fatalErrorHandler: (() -> Void)? = self.onFatalError
        pauseHandler?(!value)
        Task {
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
    public func makeOutgoingVideoView(completion: @escaping (OngoingCallContextPresentationCallVideoView?) -> Void) {
        guard let track: LocalVideoTrack = self.ensureTrack() else {
            completion(nil)
            return
        }
        let videoView: VideoView = VideoView(frame: .zero)
        videoView.track = track
        videoView.layoutMode = .fit
        let bridge: LiveKitOutgoingVideoBridge = LiveKitOutgoingVideoBridge(track: track)
        self.outgoingBridge = bridge
        videoView.add(delegate: bridge)
        let presentationView: OngoingCallContextPresentationCallVideoView = OngoingCallContextPresentationCallVideoView(
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
        completion(presentationView)
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
    public func switchVideoInput(_ deviceId: String) {
        self.deviceId = deviceId
        guard self.captureCode != .screen else {
            return
        }
        guard let track: LocalVideoTrack = self.track else {
            return
        }
        guard let cameraCapturer: CameraCapturer = track.capturer as? CameraCapturer else {
            return
        }
        let device: AVCaptureDevice? = deviceId.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceId)
        let options: CameraCaptureOptions = CameraCaptureOptions(device: device, position: .front)
        Task {
            _ = try? await cameraCapturer.set(options: options)
        }
    }


    private func ensureTrack() -> LocalVideoTrack? {
        if let existing: LocalVideoTrack = self.track {
            return existing
        }
        let created: LocalVideoTrack? = LiveKitVideoSources.createCameraTrack(captureCode: self.captureCode, deviceId: self.deviceId)
        self.track = created
        return created
    }
}



/// Reports the first rendered frame of an outgoing LiveKit view and the aspect ratio of its track.
private final class LiveKitOutgoingVideoBridge: NSObject, VideoViewDelegate {
    var onFirstFrame: ((Float) -> Void)?
    private let track: LocalVideoTrack
    private var hasReportedFirstFrame: Bool = false


    init(track: LocalVideoTrack) {
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
