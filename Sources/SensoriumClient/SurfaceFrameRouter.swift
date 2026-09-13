import Foundation
import SensoriumCore

/// What a video frame or teardown step needs from one surface's window,
/// independent of AppKit — so the decision of which surface's window a frame
/// belongs to is verifiable without a window server connection.
/// `ClientCanvasWindowController` is the only production conformer; tests
/// inject fakes.
public protocol CanvasSurfaceWindow: AnyObject {
    var surfaceID: UInt32 { get }
    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws
    func stopDecoding()
    /// Hands this window's HUD everything the viewer holds about its surface.
    /// Called on every receive tick and every periodic refresh, so a window
    /// renders whatever it is given without owning any staleness or threshold
    /// decision itself -- both live in
    /// `SessionTelemetryTracker`/`TelemetryAttentionThreshold`, and the
    /// wording and tone of every row lives in `SessionHUDPanel`.
    func updateSessionHUD(_ snapshot: SessionHUDSnapshot)
    /// Which decoder this window's decompression session actually selected,
    /// `nil` when it has none or does not track one.
    var decoderHardwareAcceleration: DecoderHardwareAccelerationStatus? { get }
    /// Whether this surface's canvas has hidden the local cursor and switched
    /// to captured relative motion. Read for the session HUD's mode row.
    var isPointerCaptured: Bool { get }
    /// The real present-to-screen latency this window's own presenter has
    /// measured -- `MetalFramePresenter.completionLatency`. Read for the
    /// session HUD's PRESENT row.
    var presentCompletionLatency: LatencySamples { get }
    /// How far past its capture time this window is holding each frame so the
    /// motion stays even. Read for the session HUD's HOLD row.
    var presentationHoldNanoseconds: Int64 { get }
    /// How many frames this window gave up rather than showed, because newer
    /// ones had already arrived. Read for the session's latency summary.
    var droppedFrameCount: Int { get }
    /// The same frames, split by where they were given up: packets the decoder
    /// never saw, and decoded frames the screen never showed. Read for the
    /// HUD, which names the two apart because they cost different things.
    var droppedBeforeDecodeCount: Int { get }
    var droppedBeforePresentCount: Int { get }
}

public extension CanvasSurfaceWindow {
    /// Defaulted so a conformer with no decode session of its own -- the test
    /// fakes -- need not carry one; the panel renders the absence honestly.
    var decoderHardwareAcceleration: DecoderHardwareAccelerationStatus? { nil }
    /// Defaulted the same way: a fake with no real canvas is never captured.
    var isPointerCaptured: Bool { false }
    /// Defaulted the same way: a fake with no real presenter has measured
    /// nothing.
    var presentCompletionLatency: LatencySamples { LatencySamples() }
    /// Defaulted the same way: a fake with no real presenter holds nothing.
    var presentationHoldNanoseconds: Int64 { 0 }
    /// Defaulted the same way: a fake that presents nothing gives up nothing.
    var droppedFrameCount: Int { 0 }
    var droppedBeforeDecodeCount: Int { 0 }
    var droppedBeforePresentCount: Int { 0 }
}

/// Demuxes a surface's video frames through its own per-surface ingress and
/// dispatches only the newest usable frame to that surface's window, bounded
/// to the fixed two-slot cap `SurfaceVideoIngress` already enforces. Holds no
/// socket or window itself, so this is the seam that proves frame routing
/// correct without either — `ClientSessionRunner` is the only production
/// caller, and it is otherwise unverifiable because it owns a live
/// `NetworkControlConnection`.
public final class SurfaceFrameRouter: @unchecked Sendable {
    private let ingress = SurfaceVideoIngress()
    private let lock = NSLock()
    private var windows: [(any CanvasSurfaceWindow)?] = [nil, nil]
    /// Where a surface's frames go when its window has an entry point that
    /// does not need the main actor. Registered alongside the window, not
    /// instead of it: everything but video still goes to the window itself.
    private var videoSinks: [(any SurfaceVideoReceiving)?] = [nil, nil]

    public init() {}

    /// Registers the entry point a surface's frames take to its decoder. A
    /// surface with one never hands video to its window, so no frame waits on
    /// whatever the window is doing.
    public func setVideoSink(_ sink: (any SurfaceVideoReceiving)?, atSurfaceID surfaceID: UInt32) {
        guard let index = Self.index(for: surfaceID) else {
            return
        }
        lock.lock()
        videoSinks[index] = sink
        lock.unlock()
    }

    /// Registers which window, if any, owns a surface. Two fixed slots, set
    /// once per session — never grown by a surfaceID read off the wire.
    public func setWindow(_ window: (any CanvasSurfaceWindow)?, atSurfaceID surfaceID: UInt32) {
        guard let index = Self.index(for: surfaceID) else {
            return
        }
        lock.lock()
        windows[index] = window
        lock.unlock()
    }

    /// Routes one surface's frame to its decoder, if that surface has one.
    /// Returns whether anything actually received it, so a caller doing
    /// per-packet bookkeeping (e.g. receipt timestamps) can tell a frame that
    /// found no window apart from one that did.
    ///
    /// A registered video sink is preferred over the window, and is what every
    /// live session uses: the sink can be reached from the thread that read the
    /// socket, and the window cannot.
    @discardableResult
    public func route(
        surfaceID: UInt32,
        frame: EncodedVideoFramePacket,
        receivedAtNanoseconds: Int64
    ) async throws -> Bool {
        await ingress.receive(surfaceID: surfaceID, frame: frame)
        if let sink = videoSink(atSurfaceID: surfaceID) {
            guard let newest = await ingress.takeNewest(surfaceID: surfaceID) else {
                return false
            }
            try sink.receive(newest, receivedAtNanoseconds: receivedAtNanoseconds)
            return true
        }
        guard let window = window(atSurfaceID: surfaceID),
              let newest = await ingress.takeNewest(surfaceID: surfaceID) else {
            return false
        }
        try window.receive(newest, receivedAtNanoseconds: receivedAtNanoseconds)
        return true
    }

    /// Routes one surface's reading to its own window only, never the other
    /// surface's -- the same fixed two-slot lookup `route` above uses, so
    /// there is no way for one surface's reading to land on the other's
    /// window by construction.
    public func updateSessionHUD(surfaceID: UInt32, snapshot: SessionHUDSnapshot) {
        window(atSurfaceID: surfaceID)?.updateSessionHUD(snapshot)
    }

    public func decoderHardwareAcceleration(surfaceID: UInt32) -> DecoderHardwareAccelerationStatus? {
        window(atSurfaceID: surfaceID)?.decoderHardwareAcceleration
    }

    public func presentCompletionLatency(surfaceID: UInt32) -> LatencySamples {
        window(atSurfaceID: surfaceID)?.presentCompletionLatency ?? LatencySamples()
    }

    public func presentationHoldNanoseconds(surfaceID: UInt32) -> Int64 {
        window(atSurfaceID: surfaceID)?.presentationHoldNanoseconds ?? 0
    }

    /// Every registered window's given-up frames added together. One number
    /// per session, because the summary line it feeds describes the session
    /// and not one of its canvases.
    public func droppedFrameCount() -> Int {
        activeWindows().reduce(0) { $0 + $1.droppedFrameCount }
    }

    /// One surface's packets given up before decoding. Per surface, unlike the
    /// session-wide total above, because the HUD that reads it describes one
    /// canvas.
    public func droppedBeforeDecodeCount(surfaceID: UInt32) -> Int {
        window(atSurfaceID: surfaceID)?.droppedBeforeDecodeCount ?? 0
    }

    /// One surface's decoded frames given up before presentation.
    public func droppedBeforePresentCount(surfaceID: UInt32) -> Int {
        window(atSurfaceID: surfaceID)?.droppedBeforePresentCount ?? 0
    }

    public func isPointerCaptured(surfaceID: UInt32) -> Bool {
        window(atSurfaceID: surfaceID)?.isPointerCaptured ?? false
    }

    /// Stops decoding on every window this router still knows about. Whoever
    /// owns the windows' visible lifecycle (closing, hiding) does so
    /// separately — this only ends the media pipeline feeding them.
    public func teardown() async {
        for window in activeWindows() {
            await window.stopDecoding()
        }
    }

    private func activeWindows() -> [any CanvasSurfaceWindow] {
        lock.lock()
        defer { lock.unlock() }
        return windows.compactMap { $0 }
    }

    private func videoSink(atSurfaceID surfaceID: UInt32) -> (any SurfaceVideoReceiving)? {
        guard let index = Self.index(for: surfaceID) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return videoSinks[index]
    }

    private func window(atSurfaceID surfaceID: UInt32) -> (any CanvasSurfaceWindow)? {
        guard let index = Self.index(for: surfaceID) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return windows[index]
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}
