import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// What one delivery from a capture stream turned out to be.
public enum ScreenCaptureDelivery: Equatable, Sendable {
    /// Pixels changed since the last delivery. The only kind that reaches the
    /// encoder, and the only kind counted as the screen changing.
    case screenChange
    /// A frame the stream attached an empty dirty-rect list to: the picture
    /// already sent, delivered again.
    case unchangedFrame
    /// `.idle`: the stream reporting no change, with no picture attached.
    case noChangeNotice
    /// Any other status update. It carries no picture, and says nothing about
    /// whether the screen changed.
    case otherStatus
}

/// ScreenCaptureKit's output callback fires for every frame-status update on
/// the stream, not only for a new frame with pixel content: `.idle` (no
/// change since the last frame), `.blank`, `.suspended`, `.started`, and
/// `.stopped` all carry no image buffer, and submitting one of those to the
/// encoder always fails `CMSampleBufferGetImageBuffer`.
///
/// `.complete` alone is not enough either. `SCStreamFrameInfoDirtyRects` is
/// documented as "the union of both rectangles that were redrawn and
/// rectangles that were moved", so a `.complete` frame carrying an empty list
/// is the same picture again, arriving because the frame interval came round
/// rather than because anything moved. Encoding it spends bits on a delta of
/// nothing and, worse, makes a screen nobody is touching read as a screen
/// changing at the frame rate -- which is exactly the reading the still-screen
/// levers exist to act on. The picture a still screen is left holding is
/// resent whole, sharp enough to read, by `refreshStillPicture`.
@available(macOS 13.0, *)
public enum ScreenCaptureFrameAdmission {
    /// A missing dirty-rect list is treated as a change. The key is optional
    /// and its value's representation is not guaranteed, and refusing to send
    /// a picture on the strength of a measurement that is absent is the worse
    /// of the two mistakes available here.
    public static func classify(status: SCFrameStatus?, dirtyRects: [CGRect]?) -> ScreenCaptureDelivery {
        switch status {
        case .some(.complete):
            guard let dirtyRects else {
                return .screenChange
            }
            return dirtyRects.isEmpty ? .unchangedFrame : .screenChange
        case .some(.idle):
            return .noChangeNotice
        default:
            return .otherStatus
        }
    }

    public static func shouldEncode(status: SCFrameStatus?, dirtyRects: [CGRect]?) -> Bool {
        classify(status: status, dirtyRects: dirtyRects) == .screenChange
    }

    static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = attachments(of: sampleBuffer),
              let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return nil
        }
        return status
    }

    /// `nil` when the stream attached no dirty-rect list, or attached one this
    /// code cannot read -- both of which mean "nothing was said about what
    /// changed", which `classify` answers conservatively.
    static func dirtyRects(of sampleBuffer: CMSampleBuffer) -> [CGRect]? {
        guard let attachments = attachments(of: sampleBuffer),
              let elements = attachments[.dirtyRects] as? [Any] else {
            return nil
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(elements.count)
        for element in elements {
            // The header documents an array of `CGRect` in `NSValue`;
            // Core Graphics' own dictionary representation is the other shape
            // a rect travels in through a Core Foundation attachment. Both are
            // read, and an element that is neither makes the whole list
            // unreadable rather than a shorter one, which would read as less
            // of the screen having changed than actually did.
            if let value = element as? NSValue {
                rects.append(value.rectValue)
            } else if let dictionary = element as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
                rects.append(rect)
            } else {
                return nil
            }
        }
        return rects
    }

    private static func attachments(of sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        return attachmentsArray.first
    }
}

/// What the host log says about a capture stream that ended without a picture
/// to show for it.
///
/// A stream that stops delivering produces no packet, no frame count and no
/// error anywhere downstream: the session simply goes quiet. These lines are
/// the only evidence that reaches the log, so each one names the display the
/// stream was capturing and what the system said.
public enum ScreenCaptureStopReport {
    /// ScreenCaptureKit ended the stream itself, which is what it does when
    /// the content it was capturing is gone.
    public static func streamStopped(displayID: UInt32, error: Error) -> String {
        "capture of display \(displayID) stopped on its own: \(error)"
    }

    /// This host asked the stream to stop and it refused. Worth saying even
    /// though the caller carries on: a stream still running after its
    /// pipeline was replaced is exactly the shape of a leak.
    public static func stopFailed(displayID: UInt32, error: Error) -> String {
        "capture of display \(displayID) could not be stopped: \(error)"
    }

    /// The first attempt to bring capture up failed and a second one, with a
    /// freshly resolved filter, follows. Only the second attempt's error can
    /// reach the caller, so this is the whole of what the first one leaves
    /// behind -- and a machine that has started needing the retry is worth
    /// seeing before it stops working altogether.
    public static func startFailed(displayID: UInt32, error: Error) -> String {
        "capture of display \(displayID) could not be started and is being tried again: \(error)"
    }
}

/// Hears ScreenCaptureKit end a stream.
///
/// A separate object rather than `ScreenCaptureSession` itself: the delegate
/// has to be supplied to `SCStream.init`, which runs before `super.init`, so
/// the session cannot name itself there. `SCStream` does not keep the
/// delegate alive, so the session holds it.
@available(macOS 13.0, *)
private final class ScreenCaptureStopObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error) -> Void

    init(onStop: @escaping @Sendable (Error) -> Void) {
        self.onStop = onStop
        super.init()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

/// One-shot and thread-safe: `claim` answers `true` to the first caller and
/// `false` to every caller after it.
private final class FirstFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else {
            return false
        }
        isClaimed = true
        return true
    }
}

@available(macOS 13.0, *)
public enum ScreenCaptureSessionError: Error, Equatable {
    /// `SCStream.updateConfiguration(_:)` arrived in macOS 14. On macOS 13 the
    /// capture frame rate is fixed for the life of the stream, so the caller
    /// hears that its request did not happen rather than believing a lever it
    /// does not have on this system was pulled.
    case liveFrameRateChangeUnsupported
}

@available(macOS 13.0, *)
@MainActor
public final class ScreenCaptureSession: NSObject, SCStreamOutput {
    public let stream: SCStream
    /// The very object this stream was built with, kept so a live frame-rate
    /// change moves one field of the configuration already in force. A fresh
    /// `SCStreamConfiguration` would carry the defaults for every field it did
    /// not restate -- cursor visibility, queue depth, pixel format -- and
    /// hand them to `updateConfiguration` as if they had been chosen.
    private let streamConfiguration: SCStreamConfiguration
    nonisolated private let frameHandler: @Sendable (CMSampleBuffer) -> Void
    /// Told what every delivery turned out to be, including the ones no frame
    /// comes of. A screen nobody is touching produces no packets at all, so a
    /// count taken anywhere downstream of the encoder cannot say what this
    /// stream is actually delivering while it sits still.
    nonisolated private let deliveryHandler: (@Sendable (ScreenCaptureDelivery) -> Void)?
    /// A stream that has delivered nothing yet has no earlier picture for a
    /// dirty-rect list to be relative to, so its first frame is a change
    /// whatever that list says. Without this, a stream whose opening frame
    /// reported no dirty region would never send a picture at all.
    nonisolated private let firstFrame = FirstFrameGate()
    /// Capture delivery and the synchronous VideoToolbox submission it drives
    /// must not queue behind AppKit/main-actor work — including the real
    /// `NSApplication` event loop `sensoriumd` runs for the session workspace.
    /// `NativeCanvasWorkspace` is the only part of this pipeline that
    /// genuinely requires the AppKit main thread; this stream's output
    /// callback is already `nonisolated` and touches no AppKit state, so it
    /// is safe to deliver on its own dedicated serial queue instead.
    nonisolated private let sampleHandlerQueue = DispatchQueue(label: "com.sensorium.host-capture-encode", qos: .userInteractive)
    /// Held for the life of the stream: `SCStream` does not keep its delegate
    /// alive, and a delegate that has been freed hears nothing.
    private let stopObserver: ScreenCaptureStopObserver

    public init(
        contentFilter: SCContentFilter,
        configuration: VideoEncoderConfiguration = .remoteDefault,
        captureTarget: CaptureCursorPolicy.Target,
        deliveryHandler: (@Sendable (ScreenCaptureDelivery) -> Void)? = nil,
        streamStoppedHandler: (@Sendable (Error) -> Void)? = nil,
        frameHandler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        let streamConfiguration = Self.streamConfiguration(
            configuration: configuration,
            captureTarget: captureTarget
        )
        let stopObserver = ScreenCaptureStopObserver { error in
            streamStoppedHandler?(error)
        }
        self.stopObserver = stopObserver
        self.stream = SCStream(
            filter: contentFilter,
            configuration: streamConfiguration,
            delegate: stopObserver
        )
        self.streamConfiguration = streamConfiguration
        self.frameHandler = frameHandler
        self.deliveryHandler = deliveryHandler
        super.init()
    }

    /// The one place an `SCStreamConfiguration` is built, so every field this
    /// capture depends on is chosen in exactly one place.
    private static func streamConfiguration(
        configuration: VideoEncoderConfiguration,
        captureTarget: CaptureCursorPolicy.Target
    ) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.captureWidth
        streamConfiguration.height = configuration.captureHeight
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        streamConfiguration.queueDepth = configuration.maxQueueDepth
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = CaptureCursorPolicy.showsCursor(for: captureTarget)
        streamConfiguration.capturesAudio = false
        if #available(macOS 14.0, *) {
            streamConfiguration.ignoreShadowsSingleWindow = true
        }
        return streamConfiguration
    }

    /// Changes how often the stream delivers frames without stopping it: the
    /// capture half of a frame-rate step, paired with the encoder's own
    /// `ExpectedFrameRate`. Capture is change-driven, so this is a ceiling on
    /// delivery rather than a promised rate.
    public func apply(framesPerSecond: Int) async throws {
        guard #available(macOS 14.0, *) else {
            throw ScreenCaptureSessionError.liveFrameRateChangeUnsupported
        }
        let previousFrameInterval = streamConfiguration.minimumFrameInterval
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        do {
            try await stream.updateConfiguration(streamConfiguration)
        } catch {
            // The stream kept the rate it had, so the object describing it
            // must say so too; otherwise the next change would be built on a
            // frame interval this capture never actually took.
            streamConfiguration.minimumFrameInterval = previousFrameInterval
            throw error
        }
    }

    public func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleHandlerQueue)
        try await stream.startCapture()
    }

    /// The output is removed before capture stops, not left to the stream's
    /// own teardown: an output still attached is a delivery path into a
    /// pipeline that has been replaced, and this session is the only object
    /// that knows it was ever added. A removal that fails is not allowed to
    /// stand between the caller and `stopCapture`, which is the half that
    /// actually ends the capture; the stop's own failure is what the caller
    /// hears about.
    public func stop() async throws {
        try? stream.removeStreamOutput(self, type: .screen)
        try await stream.stopCapture()
    }

    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        var delivery = ScreenCaptureFrameAdmission.classify(
            status: ScreenCaptureFrameAdmission.status(of: sampleBuffer),
            dirtyRects: ScreenCaptureFrameAdmission.dirtyRects(of: sampleBuffer)
        )
        if delivery == .screenChange || delivery == .unchangedFrame, firstFrame.claim() {
            delivery = .screenChange
        }
        deliveryHandler?(delivery)
        guard delivery == .screenChange else { return }
        frameHandler(sampleBuffer)
    }
}
