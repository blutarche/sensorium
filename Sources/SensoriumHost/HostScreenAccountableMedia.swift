import Foundation
import SensoriumCore

/// What `makeMedia` needs from a badge window: shown before media is ever
/// returned, hidden on every teardown path. A protocol, not
/// `HostScreenBadgeWindowController`, so a test can record show/hide
/// without opening a real `NSPanel`.
@MainActor
public protocol HostScreenBadgeDisplaying {
    func show()
    func hide()
}

extension HostScreenBadgeWindowController: HostScreenBadgeDisplaying {}

/// Thrown by `start(canvasDisplayID:onPacket:)` if it is ever called before
/// `makeMedia` has run -- `HostSessionCoordinator` never does this itself,
/// since it only obtains a `CanvasMediaStreaming` to call `start` on by
/// calling `hostScreenMediaFactory` (`makeMedia`) first, but a silent no-op
/// here would be the one soft seam in a type whose entire purpose is
/// making the accounting invariant impossible to route around.
public enum HostScreenAccountableMediaError: Error {
    case startedBeforeMakeMedia
}

/// Media that can throw away its capture and build another one at a new size
/// without ending the session it belongs to.
///
/// A host screen whose resolution the viewer changed is still the same
/// screen, watched by the same viewer, in the same session -- but a capture
/// stream is sized once, when it starts, so the stream itself has to be
/// rebuilt. Without this seam the only way to rebuild it is to make a new
/// media object, which for the accountable wrapper means ending the session
/// record and taking the badge down: a host-screen indication must stay
/// continuous, one record per session, and a blink is not continuous.
@MainActor
public protocol HostScreenCaptureReplacing: CanvasMediaStreaming {
    /// Stops the current capture and builds one sized for `configuration`,
    /// leaving everything the session is accountable for untouched. The new
    /// capture is not started: the caller starts it exactly as it starts a
    /// first one. `note` is what the session's own record should say
    /// happened, in a person's terms.
    func replaceCapture(with configuration: VideoEncoderConfiguration, note: String) async
}

/// Wraps the real host-screen media factory so streaming cannot start
/// without a session-log record and a visible badge existing first, and
/// cannot end without both ending too -- from every teardown path.
/// `HostSessionCoordinator` already calls `stop()` on whatever its
/// `hostScreenMediaFactory` returned from every one of them (a clean stop,
/// the viewer dropping, the Stop control), so making `stop()` itself the
/// one place accounting ends makes the invariant structural rather than a
/// call sequence a caller could skip.
///
/// One instance per connection, matching `HostSessionCoordinator`'s own
/// per-connection factory closure. `makeMedia(_:)` *is* that closure's
/// shape -- pass it directly as `hostScreenMediaFactory`. This type both
/// produces the media and, by conforming to `CanvasMediaStreaming` itself,
/// is the media it produces: there is no separate object a caller could
/// reach around this one to start capture without the accounting that
/// `makeMedia` already did.
@MainActor
public final class HostScreenAccountableMedia: HostScreenCaptureReplacing {
    private let rawFactory: (VideoEncoderConfiguration, VideoPacketSequencer) -> any CanvasMediaStreaming
    /// Shared across every capture this session builds, so a display-mode
    /// change never restarts the packet sequence the viewer's
    /// `VideoFrameIngress` tracks.
    private let sequencer = VideoPacketSequencer()
    private let sessionLog: HostScreenSessionLogStore
    private let deviceName: () -> String
    private let displayLabel: () -> String
    /// Fires the moment the badge's own Stop is tapped. Wired by the caller
    /// to whatever actually ends the live connection; this type's own job
    /// is only ever the accounting, never the teardown itself.
    private let onBadgeStop: @MainActor () -> Void
    /// The real `HostScreenBadgeWindowController` by default; a test
    /// supplies a fake that records `show`/`hide` instead of opening a
    /// real window.
    private let badgeFactory: (HostScreenBadgeState) -> any HostScreenBadgeDisplaying

    private var inner: (any CanvasMediaStreaming)?
    private var recordID: HostScreenSessionRecord.ID?
    /// True between `replaceCapture` and the `start` that follows it. A
    /// capture being rebuilt mid-session is the one case where a failed
    /// `start` must not end the accounting: the session is still live, the
    /// caller is about to put the display back and start a capture again,
    /// and the record and badge have to survive that.
    private var isReplacingCapture = false
    /// Exposed so a caller (or a test) can inspect what the badge shows,
    /// or drive its Stop control directly -- `HostScreenBadgeState` is
    /// already AppKit-free and testable on its own; the real window behind
    /// it is what `badgeFactory` abstracts over.
    public private(set) var badgeState: HostScreenBadgeState?
    private var badgeDisplay: (any HostScreenBadgeDisplaying)?

    public init(
        rawFactory: @escaping (VideoEncoderConfiguration, VideoPacketSequencer) -> any CanvasMediaStreaming,
        sessionLog: HostScreenSessionLogStore,
        deviceName: @escaping () -> String,
        displayLabel: @escaping () -> String,
        onBadgeStop: @escaping @MainActor () -> Void,
        badgeFactory: @escaping (HostScreenBadgeState) -> any HostScreenBadgeDisplaying = {
            HostScreenBadgeWindowController(state: $0)
        }
    ) {
        self.rawFactory = rawFactory
        self.sessionLog = sessionLog
        self.deviceName = deviceName
        self.displayLabel = displayLabel
        self.onBadgeStop = onBadgeStop
        self.badgeFactory = badgeFactory
    }

    /// `HostSessionCoordinator.hostScreenMediaFactory`'s own shape.
    /// `deviceName`/`displayLabel` are read here, not at `init`, because
    /// neither is known until the request this session streams for has
    /// actually been admitted -- `HostSessionController.hostScreenDeviceName`/
    /// `hostScreenDisplayLabel` are `nil` until then, and this method only
    /// runs after the request has been admitted.
    public func makeMedia(_ configuration: VideoEncoderConfiguration) -> any CanvasMediaStreaming {
        let name = deviceName()
        let label = displayLabel()
        recordID = sessionLog.beginSession(deviceName: name, displayLabel: label, startedAt: Date())
        let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: name, displayLabel: label))
        state.onStop = onBadgeStop
        let display = badgeFactory(state)
        display.show()
        badgeState = state
        badgeDisplay = display
        inner = rawFactory(configuration, sequencer)
        return self
    }

    public var currentStreamScale: Double { inner?.currentStreamScale ?? 1.0 }

    public func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        guard let inner else {
            throw HostScreenAccountableMediaError.startedBeforeMakeMedia
        }
        do {
            try await inner.start(canvasDisplayID: canvasDisplayID, onPacket: onPacket)
        } catch {
            // The record and badge were created by `makeMedia` and nothing
            // else will call `stop()` on media whose `start()` threw,
            // unless the capture was being rebuilt, in which case the
            // session never ended.
            if !isReplacingCapture {
                endAccounting()
            }
            throw error
        }
        isReplacingCapture = false
    }

    public func replaceCapture(with configuration: VideoEncoderConfiguration, note: String) async {
        // Only ever inside a session this object is already accounting for:
        // building a capture with no open record would be exactly the hole
        // `start(canvasDisplayID:onPacket:)` above refuses to leave.
        guard let recordID else {
            return
        }
        await inner?.stop()
        inner = rawFactory(configuration, sequencer)
        isReplacingCapture = true
        sessionLog.recordDisplayModeChange(recordID, note: note)
    }

    public func stop() async {
        await inner?.stop()
        inner = nil
        isReplacingCapture = false
        endAccounting()
    }

    public func reconfigure(streamScale: Double) async throws {
        try await inner?.reconfigure(streamScale: streamScale)
    }

    public func apply(framesPerSecond: Int) async throws {
        try await inner?.apply(framesPerSecond: framesPerSecond)
    }

    public func apply(qualityScale: Double) async throws {
        try await inner?.apply(qualityScale: qualityScale)
    }

    public func requestKeyFrame() async {
        await inner?.requestKeyFrame()
    }

    public func refreshStillPicture() async throws -> Int? {
        guard let inner else {
            return nil
        }
        return try await inner.refreshStillPicture()
    }

    public var frameCounts: HostFrameCounts {
        get async {
            guard let inner else {
                return HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
            }
            return await inner.frameCounts
        }
    }

    /// Before `makeMedia`, and after `stop`, there is no stream to report on;
    /// these name what one would open at, the same shape `currentStreamScale`
    /// above already takes.
    public var currentFramesPerSecond: Int {
        get async {
            guard let inner else { return VideoEncoderConfiguration.remoteDefault.framesPerSecond }
            return await inner.currentFramesPerSecond
        }
    }

    public var currentQualityScale: Double {
        get async {
            guard let inner else { return 1.0 }
            return await inner.currentQualityScale
        }
    }

    /// Idempotent -- `HostScreenSessionLogStore.endSession` and
    /// `HostScreenBadgeWindowController.hide` both already tolerate being
    /// called more than once, and `stop()` itself could in principle run
    /// twice if a caller races its own teardown paths.
    private func endAccounting() {
        if let recordID {
            sessionLog.endSession(recordID, endedAt: Date())
        }
        recordID = nil
        badgeDisplay?.hide()
        badgeDisplay = nil
        badgeState = nil
    }
}
